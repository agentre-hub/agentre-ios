import Foundation

/// 一条中继虚拟通道要接到哪里。寻址有且只有两种形式（规格「连接与协议」）：
/// 按对话寻址由服务端解析出承载它的机器；按机器寻址用于机器作用域的操作与新建对话。
public enum RelayTarget: Sendable, Hashable {
    case conversation(id: String)
    case machine(fingerprint: String)

    /// 通道第一帧里声明的目标，与服务端 relay_svc.TargetPrefix* 同一个词。
    public var declaration: String {
        switch self {
        case .conversation(let id): "conversation:\(id)"
        case .machine(let fingerprint): "machine:\(fingerprint)"
        }
    }
}

/// 一条通道此刻的状态。只陈述事实，不带任何错误码或对端原串：
/// 界面据它用自己的语言重述。
public enum RelayChannelStatus: Sendable, Equatable {
    /// 正在建立连接或做本通道的握手。
    case connecting
    /// 握手完成，可以收发。
    case ready
    /// 连接断了，正在自动重连。
    case reconnecting
    /// 对端的协议版本与本 App 不等：这个版本的 App 连不上你的服务端，请更新 App。
    /// 这一档不再重试。
    case updateRequired
    /// 通道已被关闭（本端关闭，或服务端判死了这一条）。
    case closed
}

/// 一条物理中继连接（WebSocket）。只收发二进制帧。
public protocol RelaySocket: Sendable {
    func send(_ frame: Data) async throws
    /// 等下一帧；连接断开时抛出。
    func receive() async throws -> Data
    func close()
}

/// 拨一条中继连接，以设备 access token 作 `Authorization: Bearer`。测试注入伪实现。
public protocol RelaySocketDialing: Sendable {
    func dial(url: URL, accessToken: String) async throws -> any RelaySocket
}
