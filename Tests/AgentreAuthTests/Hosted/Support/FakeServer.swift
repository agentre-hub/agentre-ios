import AgentreDomain
import Foundation

/// 伪 agentre-server：按路径作答 cago 信封；断网后一律抛「没有网络」。
final class FakeServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: String] = [:]
    private var reachable = true
    private var rejecting = false
    private var received: [HTTPRequest] = []

    init() {
        routes["POST /v1/oauth/device/authorize"] = """
        {"device_code":"dev-code","user_code":"ABCD-EFGH","verification_uri":"https://server.test/device",\
        "verification_uri_complete":"https://server.test/device?code=ABCD-EFGH","interval":1,"expires_in":600}
        """
        routes["POST /v1/oauth/device/token"] = """
        {"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"refresh_expires_in":86400,"device_id":7}
        """
        routes["GET /v1/auth/me"] = #"{"user_id":1,"email":"dev@example.test","display_name":"Dev","github_login":"dev"}"#
        routes["GET /v1/workspace/agents"] = #"{"agents":[{"sync_id":"agent-1","name":"Builder","exec_targets":[],"has_available_target":true}]}"#
        routes["GET /v1/workspace/projects"] = #"{"projects":[]}"#
        routes["GET /v1/engine/snapshot"] = """
        {"providers":[{"provider_key":"anthropic","name":"Anthropic","type":"anthropic","base_url":"","api_key":"sk-secret",\
        "default_model_key":"opus","models":[{"model_key":"opus","model_id":"o","name":"Opus","enabled":true},\
        {"model_key":"old","model_id":"x","name":"Old","enabled":false}]}],"cli_overlays":[],"backends":[]}
        """
    }

    func route(_ key: String, _ json: String) {
        lock.withLock { routes[key] = json }
    }

    /// 此后一切请求答 401，刷新同样被拒。
    func rejectTokens() {
        lock.withLock { rejecting = true }
    }

    func goOffline() {
        lock.withLock { reachable = false }
    }

    var requests: [HTTPRequest] { lock.withLock { received } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let json: String? = try lock.withLock {
            guard reachable else { throw URLError(.notConnectedToInternet) }
            received.append(request)
            if rejecting { return nil }
            return routes["\(request.method) \(request.url.path())"]
        }
        if lock.withLock({ rejecting }) { return HTTPResponse(status: 401, body: Data(#"{"code":401,"msg":"unauthorized"}"#.utf8)) }
        guard let json else { return HTTPResponse(status: 404, body: Data(#"{"code":404,"msg":"not found"}"#.utf8)) }
        return HTTPResponse(status: 200, body: Data(#"{"code":0,"msg":"ok","data":\#(json)}"#.utf8))
    }
}

/// 设备流的轮询间隔在测试里不真等。
struct InstantSleeper: Sleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// 记下被打开的验证地址（系统浏览器）。
@MainActor
final class RecordingOpener: VerificationOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

/// 内存里的服务器地址与显示偏好：不碰真实的 UserDefaults。
final class MemoryServerAddressStore: ServerAddressStore, @unchecked Sendable {
    private let lock = NSLock()
    private var address: ServerAddress

    init(_ address: ServerAddress) { self.address = address }

    func load() -> ServerAddress { lock.withLock { address } }
    func save(_ address: ServerAddress) { lock.withLock { self.address = address } }
}

final class MemoryPreferencesStore: DisplayPreferencesStore, @unchecked Sendable {
    func load() -> DisplayPreferences { DisplayPreferences() }
    func save(_ preferences: DisplayPreferences) {}
}

/// 一个真实的临时目录，测试结束时删掉。
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "AgentreHostedTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// 等一个条件成立（真实时间上限 `seconds` 秒）。
@MainActor
func eventually<T>(_ what: String, seconds: Double = 10, _ probe: () async throws -> T?) async throws -> T {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let value = try await probe() { return value }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw WaitTimeout(what: what)
}

struct WaitTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}
