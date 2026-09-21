import AgentreWire
import Foundation

/// 一次中继调用的收场。只有事实，不带对端的原始错误串：界面据它用自己的语言重述。
public enum RelayCallError: Error, Equatable, Sendable {
    /// 兜底期限到了还没有应答。请求可能已送达，重发可能变成两条。
    case timedOut
    /// 物理连接断了；已发出的请求结果未知。
    case disconnected
    /// 这条通道已关闭（本端关闭，或服务端判死了它）。
    case channelClosed
    /// 对端协议版本与本 App 不等：这个版本的 App 连不上你的服务端，请更新 App。
    case updateRequired
    /// 对端的应答对不上这次请求，或解不开。
    case unexpectedResponse
    /// 对端以错误码拒绝了这次请求。
    case rejected(code: Int32)
}

/// 账号信号保留通道上的一件事。载荷按原样交出，本层不解释。
public enum RelaySignal: Sendable, Equatable {
    case frame(Data)
    /// 信号那一路不可用了（服务端关掉了保留通道，或整条连接断了）。
    case closed
}

/// 一条通道交出的通知。实时帧与补齐拉回的帧走同一条路径，按 `seq` 去重后只出现一次。
public struct RelayNotification: Sendable {
    public let payload: Agentre_Wire_RpcNotification
    /// 通知所属的对话；终端、端口转发一类不属于对话的通知为 nil。
    public let conversationID: String?
    /// 持久帧的序号；预览帧与不属于对话的通知为 nil。
    public let seq: Int64?
    /// 源端时钟上的发生时刻（Unix 毫秒），只有补齐拉回的帧才带。
    public let createtime: Int64?
}

/// 一条对话上交出的一件事（`RelayChannel.events`）。
public enum RelayConversationEvent: Sendable {
    /// 一次 attach 完成：机器此刻的最高帧号。会话已中断（接不回实时流、只拉历史）时为 nil——
    /// 对端没有答最高帧号。
    case attached(latestSeq: Int64?)
    case notification(RelayNotification)
}

extension Agentre_Wire_RpcNotification {
    /// 预览帧：逐片段增量与过场状态，不带号、不入转录（协议 0.2.0）。
    var isPreviewFrame: Bool {
        switch payload {
        case .runtimeEvent(let v), .autonomousTurnEvent(let v): v.preview
        default: false
        }
    }

    /// 这条通知所属的对话与它的 seq（seq 为 0 表示非持久帧）。
    var durableKey: (conversationID: String, seq: Int64)? {
        switch payload {
        case .runtimeEvent(let v), .autonomousTurnEvent(let v): (v.conversationID, v.seq)
        case .runResultDone(let v), .autonomousTurnDone(let v): (v.conversationID, v.seq)
        case .autonomousTurnStarted(let v): (v.conversationID, v.seq)
        case .turnStarted(let v): (v.conversationID, v.seq)
        default: nil
        }
    }
}
