import Foundation

/// 本设备连接的 agentre-server 地址。
public struct ServerAddress: Sendable, Hashable {
    public static let production = ServerAddress(validated: URL(string: "https://app.agentrehub.com")!)

    public let url: URL

    /// 只接受带主机名的 http / https 地址；末尾的斜杠被去掉，拼路径时不会出现 `//`。
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil
        else { return nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { return nil }
        self.init(validated: url)
    }

    private init(validated url: URL) {
        self.url = url
    }

    public func endpoint(_ path: String) -> URL {
        url.appending(path: path)
    }
}
