import AgentreDomain
import AgentreREST
import AgentreTestSupport
import Foundation
import Testing

/// 「我」页的三个 REST 端点（agentre-server/internal/api/auth/auth.go 的 /v1/auth/me，
/// device/device.go 的 /v1/devices 与 /v1/oauth/token/revoke），经伪传输验请求形状与应答解释。
@Suite("账号 REST 客户端")
struct AccountClientTests {
    let server = ServerAddress(string: "https://dev.example.com")!

    @Test("账号信息取自 /v1/auth/me 的 data 信封")
    func profile() async throws {
        let transport = FakeHTTPTransport { _ in
            .cagoData(#"{"user_id":42,"email":"ada@example.com","display_name":"Ada","avatar_url":"","github_login":"ada","device_id":7}"#)
        }
        let profile = try await AccountClient(transport: transport).profile(server: server)
        #expect(profile == AccountProfile(userID: 42, email: "ada@example.com", displayName: "Ada", githubLogin: "ada"))
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://dev.example.com/v1/auth/me")
    }

    @Test("设备列表取自 /v1/devices：显示名、种类、在线、是不是本机逐字段读出")
    func devices() async throws {
        let transport = FakeHTTPTransport { _ in
            .cagoData(#"""
            {"devices":[
              {"id":7,"name":"iPhone","display_name":"","kind":"mobile","platform":"ios","version":"1","fingerprint":"fp-7","last_seen_at":1900000000000,"status":1,"online":true,"is_this_device":true,"protocol_mismatch":false,"daemon_commit":"","daemon_build_known":false},
              {"id":9,"name":"studio.local","display_name":"工作室 Mac","kind":"agentred","platform":"darwin","version":"0.2.0","fingerprint":"fp-9","last_seen_at":1899000000000,"status":1,"online":false,"is_this_device":false}
            ]}
            """#)
        }
        let devices = try await AccountClient(transport: transport).devices(server: server)
        #expect(devices.map(\.id) == [7, 9])
        #expect(devices[0].isThisDevice && devices[0].online)
        #expect(devices[1].shownName == "工作室 Mac")
        #expect(devices[0].shownName == "iPhone")
        #expect(devices[1].kind == "agentred")
        #expect(devices[1].lastSeenAt == 1_899_000_000_000)
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://dev.example.com/v1/devices")
    }

    @Test("撤销是 POST /v1/oauth/token/revoke，正文带 device_id")
    func revoke() async throws {
        let transport = FakeHTTPTransport { _ in .cagoData("{}") }
        try await AccountClient(transport: transport).revoke(deviceID: 9, server: server)
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://dev.example.com/v1/oauth/token/revoke")
        #expect(request.jsonBody["device_id"] as? Int == 9)
    }

    @Test("撤销被服务端以 403 拒绝（设备令牌只能撤销自己）→ revokeRefused，不是笼统的失败")
    func revokeRefused() async throws {
        let transport = FakeHTTPTransport { _ in
            HTTPResponse(status: 403, body: Data(#"{"code":1003,"msg":"forbidden"}"#.utf8))
        }
        await #expect(throws: AccountError.revokeRefused) {
            try await AccountClient(transport: transport).revoke(deviceID: 9, server: server)
        }
    }

    @Test("非 2xx 与认不出的正文都是 unexpectedResponse，对端的 msg 不被带出来")
    func failures() async throws {
        let failing = FakeHTTPTransport { _ in
            HTTPResponse(status: 500, body: Data(#"{"code":5000,"msg":"db exploded"}"#.utf8))
        }
        await #expect(throws: AuthError.unexpectedResponse(status: 500)) {
            try await AccountClient(transport: failing).profile(server: server)
        }
        let garbage = FakeHTTPTransport { _ in HTTPResponse(status: 200, body: Data("<html>".utf8)) }
        await #expect(throws: AuthError.unexpectedResponse(status: 200)) {
            try await AccountClient(transport: garbage).devices(server: server)
        }
    }
}
