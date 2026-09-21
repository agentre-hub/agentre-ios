import AgentreDomain
import AgentreStore
import AgentreWire
import Foundation
import Testing

/// 钥匙串端口的替身（真实钥匙串只在宿主目标 AgentreHostedTests 里测）。
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: Credentials?

    init(credentials: Credentials? = nil) {
        self.credentials = credentials
    }

    var stored: Credentials? { lock.withLock { credentials } }

    func loadCredentials() throws -> Credentials? { lock.withLock { credentials } }
    func saveCredentials(_ credentials: Credentials) throws { lock.withLock { self.credentials = credentials } }
    func clearCredentials() throws { lock.withLock { credentials = nil } }
    func deviceFingerprint() throws -> DeviceFingerprint { DeviceFingerprint(value: "phone-fingerprint-0001") }
}

final class InMemoryServerAddressStore: ServerAddressStore, @unchecked Sendable {
    private let lock = NSLock()
    private var address: ServerAddress
    init(_ address: ServerAddress = .production) { self.address = address }
    func load() -> ServerAddress { lock.withLock { address } }
    func save(_ address: ServerAddress) { lock.withLock { self.address = address } }
}

final class InMemoryDisplayPreferencesStore: DisplayPreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences: DisplayPreferences
    init(_ preferences: DisplayPreferences = DisplayPreferences()) { self.preferences = preferences }
    func load() -> DisplayPreferences { lock.withLock { preferences } }
    func save(_ preferences: DisplayPreferences) { lock.withLock { self.preferences = preferences } }
}

let signedInCredentials = Credentials(
    accessToken: "access-1", refreshToken: "refresh-1",
    accessTokenExpiresAt: Date(timeIntervalSince1970: 1_900_000_000),
    refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_990_000_000),
    deviceID: 7
)

let sampleProfile = AccountProfile(userID: 1, email: "ada@example.com", displayName: "Ada", githubLogin: "ada")

let thisPhone = AuthorizedDevice(
    id: 7, name: "iPhone", displayName: "", kind: "mobile", platform: "ios", fingerprint: "phone-fingerprint-0001",
    lastSeenAt: 1_900_000_000_000, online: true, isThisDevice: true
)
let studioMac = AuthorizedDevice(
    id: 9, name: "studio.local", displayName: "工作室 Mac", kind: "agentred", platform: "darwin", fingerprint: "mac-fingerprint-0009",
    lastSeenAt: 1_899_000_000_000, online: false, isThisDevice: false
)

/// 按脚本作答的账号服务，记下每次撤销。
actor FakeAccountService: AccountService {
    var profileResult: Result<AccountProfile, any Error> = .success(sampleProfile)
    var devicesResult: Result<[AuthorizedDevice], any Error> = .success([thisPhone, studioMac])
    var revokeError: (any Error)?
    private(set) var revoked: [Int64] = []
    private(set) var servers: [ServerAddress] = []

    func configure(
        profile: Result<AccountProfile, any Error>? = nil,
        devices: Result<[AuthorizedDevice], any Error>? = nil,
        revokeError: (any Error)? = nil
    ) {
        if let profile { profileResult = profile }
        if let devices { devicesResult = devices }
        self.revokeError = revokeError
    }

    func profile(server: ServerAddress) async throws -> AccountProfile {
        servers.append(server)
        return try profileResult.get()
    }

    func devices(server: ServerAddress) async throws -> [AuthorizedDevice] {
        try devicesResult.get()
    }

    func revoke(deviceID: Int64, server: ServerAddress) async throws {
        if let revokeError { throw revokeError }
        revoked.append(deviceID)
        if case .success(let devices) = devicesResult {
            devicesResult = .success(devices.filter { $0.id != deviceID })
        }
    }
}

/// 一个真实的临时目录，测试结束时删掉：本地会话库落在这里，要验的正是落盘的行被清掉。
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "AgentreAccountTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// 在临时目录上开一个真实的本地会话库，并存进上一个账号的两条会话（各带一帧转录）。
func storeWithPreviousAccountRows(_ directory: TemporaryDirectory) async throws -> LocalConversationStore {
    let store = try LocalConversationStore(directory: directory.url)
    for id in ["conv-a", "conv-b"] {
        var summary = Agentre_Wire_SessionSummary()
        summary.conversationID = id
        summary.title = "上一个账号的 \(id)"
        summary.lifecycleState = "idle"
        summary.lastMessageAt = 1_900_000_000_000
        let key = try await store.save(summary, via: "mac-fingerprint-0009")
        var delta = Agentre_Wire_TextDelta()
        delta.text = "secret \(id)"
        var event = Agentre_Wire_RuntimeEventNotification()
        event.conversationID = id
        event.textDelta = delta
        var payload = Agentre_Wire_RpcNotification()
        payload.runtimeEvent = event
        try await store.record([IncomingFrame(conversationID: id, seq: 1, createtime: 1, payload: payload)], via: "mac-fingerprint-0009")
        #expect(try await store.transcript(key).count == 1)
    }
    #expect(try await store.conversations().count == 2)
    return store
}

/// 库清空失败的替身：用来证明登出不因库出错而停在半路。
actor FailingConversationStore: ConversationStore {
    private(set) var removeAllCalls = 0
    func conversations() async throws -> [SavedConversation] { [] }
    func conversation(_ key: ConversationKey) async throws -> SavedConversation? { nil }
    func transcript(_ key: ConversationKey) async throws -> [TranscriptFrame] { [] }
    func latestSeq(_ key: ConversationKey) async throws -> Int64 { 0 }
    func markRead(_ key: ConversationKey) async throws {}
    func delete(_ key: ConversationKey) async throws {}
    func removeAll() async throws {
        removeAllCalls += 1
        throw CocoaError(.fileWriteNoPermission)
    }
    func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
