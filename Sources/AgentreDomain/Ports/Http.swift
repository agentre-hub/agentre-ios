import Foundation

/// 一次 HTTP 请求的传输无关描述。领域层与 REST 层只经它说话，测试注入伪实现。
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

/// 发一次请求、拿回状态与正文。传输层失败（断网、超时）以抛错表达；
/// 任何 HTTP 状态码都是一次成功的传输，由调用方解释。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
