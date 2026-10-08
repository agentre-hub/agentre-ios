import AgentreDomain
import Foundation

/// 中继客户端端点。原生端直接以设备 access token 作 `Authorization` 头，
/// 不用浏览器那套票据与子协议搬运。
public enum RelayEndpoint {
    public static func clientURL(for server: ServerAddress) -> URL {
        var components = URLComponents(url: server.endpoint("v1/relay/client"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        return components.url!
    }
}

/// 以 URLSessionWebSocketTask 拨真实的中继连接。
public struct URLSessionRelayDialer: RelaySocketDialing {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func makeTask(url: URL, accessToken: String) -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = RelayEnvelope.readLimit
        return task
    }

    public func dial(url: URL, accessToken: String) async throws -> any RelaySocket {
        let task = makeTask(url: url, accessToken: accessToken)
        task.resume()
        return URLSessionRelaySocket(task: task)
    }
}

struct URLSessionRelaySocket: RelaySocket {
    let task: URLSessionWebSocketTask

    func send(_ frame: Data) async throws {
        try await task.send(.data(frame))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        // 中继只收发二进制帧；文本帧是协议违例，按一帧坏帧交给上层丢掉。
        case .string: return Data()
        @unknown default: return Data()
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
