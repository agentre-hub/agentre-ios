import AgentreDomain
import Foundation

/// agentre-server（cago）的应答形状：成功时业务数据在 `data` 里；
/// OAuth 端点的失败在 cago 字段之外另附 RFC 8628 的 `error`。
enum CagoEnvelope {
    private struct Wrapped<T: Decodable>: Decodable {
        let data: T
    }

    private struct OAuthFailure: Decodable {
        let error: String?
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    static func decodeData<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        do {
            return try decoder.decode(Wrapped<T>.self, from: response.body).data
        } catch {
            throw AuthError.unexpectedResponse(status: response.status)
        }
    }

    /// 失败应答里的 RFC 8628 错误字面量；不是 JSON 或没有该字段时为 nil。
    static func oauthError(in response: HTTPResponse) -> String? {
        (try? JSONDecoder().decode(OAuthFailure.self, from: response.body))?.error
    }
}

extension HTTPResponse {
    var isSuccess: Bool { (200..<300).contains(status) }
}

extension HTTPRequest {
    /// 带 JSON 正文（蛇形字段名）的 POST。
    static func postJSON(_ url: URL, _ body: some Encodable) throws -> HTTPRequest {
        HTTPRequest(method: "POST", url: url, headers: ["Content-Type": "application/json"], body: try CagoEnvelope.encoder.encode(body))
    }
}
