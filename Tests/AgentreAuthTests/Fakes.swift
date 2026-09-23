import AgentreDomain
import Foundation

final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: Credentials?
    private var fingerprint: DeviceFingerprint?

    init(credentials: Credentials? = nil, fingerprint: DeviceFingerprint? = nil) {
        self.credentials = credentials
        self.fingerprint = fingerprint
    }

    var stored: Credentials? { lock.withLock { credentials } }
    var storedFingerprint: DeviceFingerprint? { lock.withLock { fingerprint } }

    func loadCredentials() throws -> Credentials? { lock.withLock { credentials } }
    func saveCredentials(_ credentials: Credentials) throws { lock.withLock { self.credentials = credentials } }
    /// 接下来这么多次清除抛错（钥匙串一时出错）。
    var failingClears = 0
    func clearCredentials() throws {
        try lock.withLock {
            if failingClears > 0 {
                failingClears -= 1
                throw CocoaError(.fileWriteUnknown)
            }
            credentials = nil
        }
    }
    func deviceFingerprint() throws -> DeviceFingerprint {
        lock.withLock {
            if let fingerprint { return fingerprint }
            let generated = DeviceFingerprint.generate()
            fingerprint = generated
            return generated
        }
    }
}

final class InMemoryServerAddressStore: ServerAddressStore, @unchecked Sendable {
    private let lock = NSLock()
    private var address: ServerAddress
    init(_ address: ServerAddress = .production) { self.address = address }
    func load() -> ServerAddress { lock.withLock { address } }
    func save(_ address: ServerAddress) { lock.withLock { self.address = address } }
}

@MainActor
final class RecordingOpener: VerificationOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

/// 伪时钟：每次等待都把「现在」推后同样的时长，并记下等待的时长。
final class FakeClock: Sleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private var waits: [Duration] = []

    var now: Date { lock.withLock { current } }
    var sleeps: [Duration] { lock.withLock { waits } }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        lock.withLock {
            waits.append(duration)
            current = current.addingTimeInterval(TimeInterval(duration.components.seconds))
        }
    }
}

/// 按脚本逐次作答的设备流；脚本用尽后一直答 pending。
final class ScriptedDeviceAuth: DeviceAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<DeviceTokenPoll, any Error>]
    private let authorization: Result<DeviceAuthorization, any Error>
    private(set) var authorizedWith: [(DeviceFingerprint, ServerAddress)] = []
    private(set) var polledCodes: [String] = []
    /// 每次轮询时回调，用来观察轮询发生那一刻的外部状态。
    var onPoll: (@Sendable () async -> Void)?

    init(authorization: Result<DeviceAuthorization, any Error> = .success(.sample), polls: [Result<DeviceTokenPoll, any Error>]) {
        self.authorization = authorization
        self.script = polls
    }

    func authorize(fingerprint: DeviceFingerprint, server: ServerAddress) async throws -> DeviceAuthorization {
        lock.withLock { authorizedWith.append((fingerprint, server)) }
        return try authorization.get()
    }

    func pollToken(deviceCode: String, server: ServerAddress) async throws -> DeviceTokenPoll {
        await onPoll?()
        let next: Result<DeviceTokenPoll, any Error> = lock.withLock {
            polledCodes.append(deviceCode)
            return script.isEmpty ? .success(.pending) : script.removeFirst()
        }
        return try next.get()
    }
}

struct TransportDown: Error {}

extension DeviceAuthorization {
    static let sample = DeviceAuthorization(
        deviceCode: "dev-code-1",
        userCode: "ABCD-EFGH",
        verificationURIComplete: URL(string: "https://app.agentrehub.com/device?user_code=ABCD-EFGH")!,
        interval: .seconds(5),
        expiresIn: .seconds(600)
    )
}

extension TokenGrant {
    static let sample = TokenGrant(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: .seconds(900), refreshExpiresIn: .seconds(86_400))
}
