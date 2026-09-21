import AgentreDomain
import AgentreWire

/// 一帧对会话元数据说了什么，逐条对照服务端 mirror_svc/notification.go 与 mirror.go 的
/// followTurn / followWaiter。
extension Agentre_Wire_RpcNotification {
    /// 轮次边界：开始 → running；结束 → idle，故障收场 → failed。其余帧为 nil。
    var turnBoundaryLifecycle: String? {
        switch payload {
        case .turnStarted, .autonomousTurnStarted:
            SavedConversation.Lifecycle.running
        case .runResultDone(let done), .autonomousTurnDone(let done):
            isTurnFailure(message: done.stopErrorMessage, code: done.stopErrorCode)
                ? SavedConversation.Lifecycle.failed : SavedConversation.Lifecycle.idle
        default:
            nil
        }
    }

    /// 待决边界与它的请求标识。只认工具审批与提问两族——daemon 的 waitingForInput
    /// 判据逐字就是「待决审批数 + 待决提问数 > 0」；执行审批不在其中。
    var waiterSignal: WaiterSignal? {
        guard case .runtimeEvent(let event) = payload else { return nil }
        switch event.event {
        case .toolPermissionRequest(let r): return .opened(r.requestID)
        case .toolPermissionResolved(let r): return .closed(r.requestID)
        case .userAskRequest(let r): return .opened(r.requestID)
        case .userAskResolved(let r): return .closed(r.requestID)
        default: return nil
        }
    }
}

enum WaiterSignal: Equatable {
    case opened(String)
    case closed(String)
}

/// 用户自己按停止时的 sentinel（agentre/pkg/wire/turnstate.AbortedCode）。
let abortedStopCode: Int32 = -32013

/// 与 agentre/pkg/wire/turnstate.IsFailure 同一句话：有停止文案且不是用户中断 = 故障。
func isTurnFailure(message: String, code: Int32) -> Bool {
    !message.isEmpty && code != abortedStopCode
}
