import AgentreDomain
import AgentreRelay
import Foundation

/// 装配处的失败重述：通道层的 `RelayCallError` 先换成适配器的 `RelayFailure`（它自己说得出事实），
/// 其余交给 `FailureFact(presenting:)`。
enum AppFailure {
    static func fact(for error: any Error) -> FailureFact? {
        switch error {
        case let failure as RelayCallError: RelayFailure(failure).fact
        default: FailureFact(presenting: error)
        }
    }
}
