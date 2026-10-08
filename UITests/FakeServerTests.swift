import XCTest

/// 伪服务端自身的守卫：它认不得的端点必须被记下，主线流程末尾的「没有调用伪服务端不认得的端点」才有意义。
final class FakeServerTests: XCTestCase {
    func testUnknownEndpointWithoutTokenIsRecorded() async throws {
        let server = try FakeAgentreServer(machines: [])
        defer { server.stop() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(server.baseURL)/v1/oauth/token/refresh")))
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"refresh_token":"uitest-refresh-1"}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(server.unhandledRequests, ["POST /v1/oauth/token/refresh"])
    }
}
