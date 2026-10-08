import AgentreDomain
import Foundation

/// 给请求带上设备访问令牌的传输。遇 401 以刷新令牌换新后重试原请求一次；
/// 刷新本身由 `AccessTokenProvider` 保证同一时刻只进行一次。
public struct AuthorizedTransport: HTTPTransport {
    private let inner: HTTPTransport
    private let tokens: AccessTokenProvider

    public init(inner: HTTPTransport, tokens: AccessTokenProvider) {
        self.inner = inner
        self.tokens = tokens
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let token = try await tokens.accessToken()
        let response = try await inner.send(request.bearer(token))
        guard response.status == 401 else { return response }
        let renewed = try await tokens.refreshedToken(replacing: token)
        return try await inner.send(request.bearer(renewed))
    }
}

private extension HTTPRequest {
    func bearer(_ token: String) -> HTTPRequest {
        var copy = self
        copy.headers["Authorization"] = "Bearer \(token)"
        return copy
    }
}
