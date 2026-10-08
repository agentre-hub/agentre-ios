import Foundation

/// 本设备连接的 agentre-server 地址。
public struct ServerAddress: Sendable, Hashable {
    public static let production = ServerAddress(validated: URL(string: "https://app.agentrehub.com")!)

    public let url: URL

    /// 只接受带主机名的 http / https 地址；末尾的斜杠被去掉，拼路径时不会出现 `//`。
    /// 协议与主机名一律小写、写明的默认端口去掉：同一台服务器只有一种写法，换个大小写不算换服务器
    /// （换服务器即登出、清空本地库）；中继地址按小写协议换成 ws / wss。
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil
        else { return nil }
        components.scheme = scheme
        if host != host.lowercased() { components.host = host.lowercased() }
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
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
