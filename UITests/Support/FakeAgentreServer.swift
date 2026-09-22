import Foundation

/// 伪 agentre-server：设备流、账号、设备名册与撤销、工作区、引擎目录这些 REST 端点，外加中继
/// `/v1/relay/client`。应答形状照 agentre-server（cago 的 `{"code","msg","data"}` 信封；设备流的失败
/// 另附 RFC 8628 的 `error`，状态码与 device_ctr.oauthErrToHTTP 同）。
///
/// 设备流的「浏览器那一半」：App 打开的验证地址就指向这里，浏览器取到 `/device?user_code=…`
/// 这一页即视为用户批准——此后轮询换得令牌。于是断言「App 直接打开了带确认码的验证地址」就是断言批准发生了。
///
/// 除 `init` 外一切状态只在 `server.queue` 上读写；测试经 `read` / `perform` 同步进出。
final class FakeAgentreServer: @unchecked Sendable {
    static let userCode = "UITS-4821"
    static let phoneDeviceID: Int64 = 7

    private var server: LoopbackServer!
    let relay: FakeRelay

    // 设备流与令牌（queue 上）
    private var deviceCode: String?
    private var approved = false
    private var tokenSerial = 0
    private var liveTokens: Set<String> = []
    private var phoneFingerprint = ""
    private var phoneName = ""
    private var revokedDevices: [Int64] = []
    private var unhandled: [String] = []
    private var verificationVisits: [String] = []

    init(machines: [FakeAgentred]) throws {
        relay = FakeRelay(machines: machines)
        server = try LoopbackServer { [unowned self] request in self.route(request) }
        relay.attach(queue: server.queue) { [unowned self] token in self.liveTokens.contains(token) }
    }

    var baseURL: String { server.baseURL }

    func stop() { server.stop() }

    /// 在服务端的队列上同步读一次状态。
    func read<T>(_ body: (FakeAgentreServer) -> T) -> T {
        server.queue.sync { body(self) }
    }

    /// 在服务端的队列上同步做一件事（推帧、断连接……）。
    func perform(_ body: (FakeAgentreServer) -> Void) {
        server.queue.sync { body(self) }
    }

    var revoked: [Int64] { read { $0.revokedDevices } }
    /// 没有对应端点的请求（App 调了伪服务端不认得的东西——伪对端与真实对端不同形了）。
    var unhandledRequests: [String] { read { $0.unhandled } }
    var verificationPageVisits: [String] { read { $0.verificationVisits } }
    var signedInFingerprint: String { read { $0.phoneFingerprint } }

    // MARK: 路由

    private func route(_ request: LoopbackServer.Request) -> LoopbackServer.Outcome {
        switch (request.method, request.path) {
        case ("POST", "/v1/oauth/device/authorize"):
            return .respond(authorize(request))
        case ("POST", "/v1/oauth/device/token"):
            return .respond(pollToken(request))
        case ("GET", "/device"):
            // 浏览器打开的验证页：带着对的确认码来，就是用户在这一页上批准了。
            verificationVisits.append(request.query["user_code"] ?? "")
            if request.query["user_code"] == Self.userCode { approved = true }
            return .respond(.init(status: 200, body: Data("<html><body><h1>Approved</h1></body></html>".utf8), contentType: "text/html"))
        case ("GET", "/v1/relay/client"):
            guard let token = request.bearer, liveTokens.contains(token) else { return .respond(Self.failure(401, code: 401)) }
            return .upgrade(relay.client(for: phoneFingerprint))
        default:
            break
        }
        // 其余都在设备令牌那一组：令牌不认得（没发过、已撤销）一律 401。
        guard let token = request.bearer, liveTokens.contains(token) else { return .respond(Self.failure(401, code: 401)) }
        switch (request.method, request.path) {
        case ("GET", "/v1/auth/me"):
            return .respond(Self.ok(#"{"user_id":1,"email":"uitest@example.test","display_name":"UI Tester","github_login":"uitester"}"#))
        case ("GET", "/v1/devices"):
            return .respond(Self.ok(devicesJSON()))
        case ("POST", "/v1/oauth/token/revoke"):
            return .respond(revoke(request))
        case ("GET", "/v1/workspace/agents"):
            return .respond(Self.ok(Self.agentsJSON))
        case ("GET", "/v1/workspace/projects"):
            return .respond(Self.ok(#"{"projects":[]}"#))
        case ("GET", "/v1/workspace/dispatch-target"):
            guard request.query["agent_sync_id"] == Self.agentSyncID else { return .respond(Self.failure(400, code: 400)) }
            return .respond(Self.ok(Self.dispatchPlanJSON))
        case ("GET", "/v1/engine/snapshot"):
            return .respond(Self.ok(Self.engineJSON))
        default:
            unhandled.append("\(request.method) \(request.path)")
            return .respond(Self.failure(404, code: 404))
        }
    }

    private func authorize(_ request: LoopbackServer.Request) -> LoopbackServer.Response {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        guard body["device_kind"] as? String == "mobile", let fingerprint = body["fingerprint"] as? String, !fingerprint.isEmpty else {
            return Self.failure(400, code: 400)
        }
        phoneFingerprint = fingerprint
        phoneName = body["name"] as? String ?? ""
        let code = "device-code-\(UUID().uuidString)"
        deviceCode = code
        approved = false
        return Self.ok("""
        {"device_code":"\(code)","user_code":"\(Self.userCode)","verification_uri":"\(baseURL)/device",\
        "verification_uri_complete":"\(baseURL)/device?user_code=\(Self.userCode)","interval":1,"expires_in":600}
        """)
    }

    private func pollToken(_ request: LoopbackServer.Request) -> LoopbackServer.Response {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        guard body["grant_type"] as? String == "urn:ietf:params:oauth:grant-type:device_code",
              let code = body["device_code"] as? String, code == deviceCode
        else { return Self.oauthFailure(400, "invalid_grant") }
        guard approved else { return Self.oauthFailure(400, "authorization_pending") }
        deviceCode = nil
        tokenSerial += 1
        let token = "uitest-access-\(tokenSerial)"
        liveTokens.insert(token)
        return Self.ok("""
        {"access_token":"\(token)","refresh_token":"uitest-refresh-\(tokenSerial)","expires_in":3600,\
        "refresh_expires_in":86400,"device_id":\(Self.phoneDeviceID)}
        """)
    }

    /// 以设备令牌调用时只准撤销本机（device_ctr.Revoke：目标不是调用者即 403）；撤销后它的令牌作废、中继连接断开。
    private func revoke(_ request: LoopbackServer.Request) -> LoopbackServer.Response {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let target = (body["device_id"] as? NSNumber)?.int64Value ?? Self.phoneDeviceID
        guard target == Self.phoneDeviceID else { return Self.failure(403, code: 403) }
        revokedDevices.append(target)
        liveTokens = []
        relay.dropAll()
        return Self.ok("{}")
    }

    private func devicesJSON() -> String {
        let machines = relay.machines.map { machine in
            """
            {"id":\(machine.deviceID),"name":"\(machine.name)","display_name":"","kind":"agentred","platform":"linux",\
            "version":"0.1.0","fingerprint":"\(machine.fingerprint)","last_seen_at":\(Self.nowMillis),"online":true,"is_this_device":false}
            """
        }
        let desktop = """
        {"id":3,"name":"old-desktop","display_name":"","kind":"desktop","platform":"darwin","version":"0.1.0",\
        "fingerprint":"fp-old-desktop","last_seen_at":\(Self.nowMillis - 3 * 86_400_000),"online":false,"is_this_device":false}
        """
        let phone = """
        {"id":\(Self.phoneDeviceID),"name":"\(phoneName)","display_name":"","kind":"mobile","platform":"ios","version":"0.1.0",\
        "fingerprint":"\(phoneFingerprint)","last_seen_at":\(Self.nowMillis),"online":true,"is_this_device":true}
        """
        return #"{"devices":["# + (machines + [desktop, phone]).joined(separator: ",") + "]}"
    }

    // MARK: 固定数据

    static let agentSyncID = "agent-builder"
    static let agentName = "Builder"
    static let workingDirectory = "/srv/uitest/work"

    private static var agentsJSON: String {
        """
        {"agents":[{"sync_id":"\(agentSyncID)","name":"\(agentName)","project_sync_ids":[],\
        "exec_targets":[{"rank":1,"backend_sync_id":"backend-claude","device_unspecified":false,"device_name":"\(FakeAgentred.boxName)",\
        "backend_type":"claudecode","availability":"available","current":true}],"has_available_target":true}]}
        """
    }

    private static var dispatchPlanJSON: String {
        """
        {"agent_sync_id":"\(agentSyncID)","tiers":[{"rank":1,"backend_sync_id":"backend-claude","device_name":"\(FakeAgentred.boxName)",\
        "backend_type":"claudecode","kind":"agentred","availability":"available"}],\
        "chosen":{"device_fingerprint":"\(FakeAgentred.boxFingerprint)","device_name":"\(FakeAgentred.boxName)",\
        "backend_sync_id":"backend-claude","backend_type":"claudecode","kind":"agentred","cwd":"\(workingDirectory)"}}
        """
    }

    private static let engineJSON = """
    {"providers":[{"provider_key":"anthropic","name":"Anthropic","type":"anthropic","base_url":"","api_key":"sk-uitest",\
    "default_model_key":"sonnet","models":[{"model_key":"sonnet","model_id":"claude-sonnet","name":"Sonnet","enabled":true}]}],\
    "cli_overlays":[],"backends":[]}
    """

    static var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func ok(_ data: String) -> LoopbackServer.Response {
        .init(status: 200, body: Data(#"{"code":0,"msg":"ok","data":\#(data)}"#.utf8))
    }

    private static func failure(_ status: Int, code: Int) -> LoopbackServer.Response {
        .init(status: status, body: Data(#"{"code":\#(code),"msg":"uitest failure"}"#.utf8))
    }

    private static func oauthFailure(_ status: Int, _ error: String) -> LoopbackServer.Response {
        .init(status: status, body: Data(#"{"code":\#(status),"msg":"\#(error)","error":"\#(error)"}"#.utf8))
    }
}
