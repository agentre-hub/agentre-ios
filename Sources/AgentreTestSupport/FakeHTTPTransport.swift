import AgentreDomain
import Foundation

/// 注入给 REST 层的伪传输：按调用方给的处理函数作答，并记下收到的每一次请求。
public actor FakeHTTPTransport: HTTPTransport {
    public typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    public private(set) var requests: [HTTPRequest] = []
    private let handler: Handler

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try await handler(request)
    }
}

extension HTTPResponse {
    /// cago 的成功信封：`{"code":0,"msg":"ok","data":…}`。
    public static func cagoData(_ json: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(#"{"code":0,"msg":"ok","data":\#(json)}"#.utf8))
    }

    /// 服务端 OAuth 端点的失败应答：cago 业务码之外附 RFC 8628 的 `error` 字段。
    public static func oauthError(_ error: String, status: Int, code: Int = 0) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(#"{"code":\#(code),"msg":"x","error":"\#(error)","error_description":"x"}"#.utf8))
    }
}

extension HTTPRequest {
    /// 请求正文按 JSON 对象解开；不是 JSON 对象时为空字典。
    public var jsonBody: [String: Any] {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return object
    }
}
