import AgentreDomain
import AgentreREST
import AgentreTestSupport
import Foundation
import Testing

struct DeviceAuthClientTests {
    let server = ServerAddress(string: "http://docker.local:8443")!

    func client(_ transport: FakeHTTPTransport) -> DeviceAuthClient {
        DeviceAuthClient(transport: transport, platform: "ios", version: "0.1.0", deviceName: "iPhone")
    }

    @Test("发起：以 mobile 种类、本设备指纹 POST 授权端点，解出带确认码的验证地址")
    func authorize() async throws {
        let transport = FakeHTTPTransport { _ in
            .cagoData(#"{"device_code":"dc","user_code":"UC-1","verification_uri":"https://s/device","verification_uri_complete":"https://s/device?user_code=UC-1","interval":5,"expires_in":600}"#)
        }

        let authorization = try await client(transport).authorize(fingerprint: DeviceFingerprint(value: "fp-12345678"), server: server)

        #expect(authorization == DeviceAuthorization(
            deviceCode: "dc", userCode: "UC-1",
            verificationURIComplete: URL(string: "https://s/device?user_code=UC-1")!,
            interval: .seconds(5), expiresIn: .seconds(600)
        ))
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://docker.local:8443/v1/oauth/device/authorize")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = request.jsonBody
        #expect(body["device_kind"] as? String == "mobile")
        #expect(body["fingerprint"] as? String == "fp-12345678")
        #expect(body["platform"] as? String == "ios")
        #expect(body["version"] as? String == "0.1.0")
        #expect(body["name"] as? String == "iPhone")
    }

    @Test("发起：应答缺带确认码的验证地址即视为认不出的应答")
    func authorizeRejectsIncompleteResponse() async {
        let transport = FakeHTTPTransport { _ in
            .cagoData(#"{"device_code":"dc","user_code":"UC-1","verification_uri":"https://s/device","verification_uri_complete":"","interval":5,"expires_in":600}"#)
        }
        await #expect(throws: AuthError.unexpectedResponse(status: 200)) {
            try await client(transport).authorize(fingerprint: DeviceFingerprint(value: "fp-12345678"), server: server)
        }
    }

    @Test("轮询：按 HTTP 状态与 RFC 8628 error 字段映射到授权中 / 放慢 / 过期 / 被拒", arguments: [
        (HTTPResponse.oauthError("authorization_pending", status: 400, code: 30200), DeviceTokenPoll.pending),
        (HTTPResponse.oauthError("slow_down", status: 429, code: 30201), DeviceTokenPoll.slowDown),
        (HTTPResponse.oauthError("expired_token", status: 410, code: 30202), DeviceTokenPoll.expired),
        (HTTPResponse.oauthError("access_denied", status: 403, code: 30203), DeviceTokenPoll.denied),
    ])
    func pollOutcomes(response: HTTPResponse, expected: DeviceTokenPoll) async throws {
        let transport = FakeHTTPTransport { _ in response }

        let poll = try await client(transport).pollToken(deviceCode: "dc", server: server)

        #expect(poll == expected)
        let request = try #require(await transport.requests.first)
        #expect(request.url.path == "/v1/oauth/device/token")
        #expect(request.jsonBody["grant_type"] as? String == "urn:ietf:params:oauth:grant-type:device_code")
        #expect(request.jsonBody["device_code"] as? String == "dc")
    }

    @Test("轮询成功：解出令牌与设备 id")
    func pollAuthorized() async throws {
        let transport = FakeHTTPTransport { _ in
            .cagoData(#"{"access_token":"at","token_type":"Bearer","expires_in":900,"refresh_token":"rt","refresh_expires_in":86400,"device_id":42}"#)
        }

        let poll = try await client(transport).pollToken(deviceCode: "dc", server: server)

        #expect(poll == .authorized(
            TokenGrant(accessToken: "at", refreshToken: "rt", expiresIn: .seconds(900), refreshExpiresIn: .seconds(86_400)),
            deviceID: 42
        ))
    }

    @Test("轮询成功却缺令牌或设备 id：视为认不出的应答，不落半份凭据", arguments: [
        #"{"access_token":"at","token_type":"Bearer","expires_in":900,"refresh_token":"rt","refresh_expires_in":86400}"#,
        #"{"access_token":"","token_type":"Bearer","expires_in":900,"refresh_token":"rt","refresh_expires_in":86400,"device_id":42}"#,
    ])
    func pollAuthorizedIncomplete(json: String) async {
        let transport = FakeHTTPTransport { _ in .cagoData(json) }
        await #expect(throws: AuthError.unexpectedResponse(status: 200)) {
            try await client(transport).pollToken(deviceCode: "dc", server: server)
        }
    }

    @Test("轮询：认不出的失败（invalid_grant、5xx）抛错，不被当成授权中")
    func pollUnknownFailure() async {
        for response in [HTTPResponse.oauthError("invalid_grant", status: 400), HTTPResponse(status: 502, body: Data("bad gateway".utf8))] {
            let transport = FakeHTTPTransport { _ in response }
            await #expect(throws: AuthError.unexpectedResponse(status: response.status)) {
                try await client(transport).pollToken(deviceCode: "dc", server: server)
            }
        }
    }

    @Test("刷新：POST 刷新端点并解出新令牌")
    func refresh() async throws {
        let transport = FakeHTTPTransport { _ in
            .cagoData(#"{"access_token":"at2","expires_in":900,"refresh_token":"rt2","refresh_expires_in":86400}"#)
        }

        let grant = try await client(transport).refresh(refreshToken: "rt1", server: server)

        #expect(grant == TokenGrant(accessToken: "at2", refreshToken: "rt2", expiresIn: .seconds(900), refreshExpiresIn: .seconds(86_400)))
        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString == "http://docker.local:8443/v1/oauth/token/refresh")
        #expect(request.jsonBody["refresh_token"] as? String == "rt1")
    }

    @Test("刷新：服务端拒绝（4xx）即 refreshRejected；5xx 不是登出", arguments: [400, 401, 403])
    func refreshRejected(status: Int) async {
        let transport = FakeHTTPTransport { _ in .oauthError("invalid_grant", status: status) }
        await #expect(throws: AuthError.refreshRejected) {
            try await client(transport).refresh(refreshToken: "rt1", server: server)
        }
    }

    @Test("刷新：没带 invalid_grant 的 401 / 403 也是拒绝", arguments: [401, 403])
    func refreshRejectedWithoutOAuthError(status: Int) async {
        let transport = FakeHTTPTransport { _ in HTTPResponse(status: status) }
        await #expect(throws: AuthError.refreshRejected) {
            try await client(transport).refresh(refreshToken: "rt1", server: server)
        }
    }

    @Test("刷新：限流、超时与不带 invalid_grant 的其它 4xx 不是拒绝，不登出", arguments: [400, 404, 408, 429])
    func refreshTransientIsNotRejection(status: Int) async {
        let transport = FakeHTTPTransport { _ in HTTPResponse(status: status) }
        await #expect(throws: AuthError.unexpectedResponse(status: status)) {
            try await client(transport).refresh(refreshToken: "rt1", server: server)
        }
    }

    @Test("刷新：5xx 抛认不出的应答而不是 refreshRejected")
    func refreshServerError() async {
        let transport = FakeHTTPTransport { _ in HTTPResponse(status: 503) }
        await #expect(throws: AuthError.unexpectedResponse(status: 503)) {
            try await client(transport).refresh(refreshToken: "rt1", server: server)
        }
    }
}
