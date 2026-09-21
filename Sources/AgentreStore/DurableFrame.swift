import AgentreWire

/// wire 通知里与落库相关的三件事，逐条对照服务端 mirror_svc/notification.go。
extension Agentre_Wire_RpcNotification {
    /// 预览帧：逐片段增量与过场状态，不带号、不入转录，丢了就丢了（协议 0.2.0）。
    var isPreview: Bool {
        switch payload {
        case .runtimeEvent(let v), .autonomousTurnEvent(let v): v.preview
        default: false
        }
    }

    /// 这条通知所属的对话；不属于对话的（终端、端口转发）为 nil。
    var durableConversationID: String? {
        switch payload {
        case .runtimeEvent(let v), .autonomousTurnEvent(let v): v.conversationID
        case .runResultDone(let v), .autonomousTurnDone(let v): v.conversationID
        case .autonomousTurnStarted(let v): v.conversationID
        case .turnStarted(let v): v.conversationID
        default: nil
        }
    }

    /// 把载体上的帧号盖进载荷：实时与补齐两路落下的是同一个形状（setNotificationSeq）。
    mutating func stamp(seq: Int64) {
        switch payload {
        case .runtimeEvent(var v):
            v.seq = seq
            runtimeEvent = v
        case .autonomousTurnEvent(var v):
            v.seq = seq
            autonomousTurnEvent = v
        case .runResultDone(var v):
            v.seq = seq
            runResultDone = v
        case .autonomousTurnDone(var v):
            v.seq = seq
            autonomousTurnDone = v
        case .autonomousTurnStarted(var v):
            v.seq = seq
            autonomousTurnStarted = v
        case .turnStarted(var v):
            v.seq = seq
            turnStarted = v
        default:
            return
        }
    }
}
