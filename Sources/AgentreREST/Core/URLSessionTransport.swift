import AgentreDomain
import Foundation

/// 经 URLSession 发请求的真实传输。
///
/// 默认用一条不落盘的会话：应答不进应用的 URL 缓存（`URLSession.shared` 的缓存在沙盒里落盘），
/// 而引擎目录的应答里带着供应商的 API key——凭据只存于钥匙串（规格「兼容性与隐私」）。
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = URLSessionTransport.storeless()) {
        self.session = session
    }

    /// 不带任何 URL 缓存、不留 Cookie 的会话。
    public static func storeless() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HTTPResponse(status: http.statusCode, body: data)
    }
}
