import AgentreDomain
import AgentreRelay
import Foundation

/// 装配处的失败重述：`FailureFact(presenting:)` 只认 REST 与系统网络的错误，中继的失败
/// 在这里先按 `RelayFailure.fact` 说成事实，其余交给它。
enum AppFailure {
    static func fact(for error: any Error) -> FailureFact? {
        switch error {
        case let failure as RelayFailure: failure.fact
        case let failure as RelayCallError: RelayFailure(failure).fact
        default: FailureFact(presenting: error)
        }
    }
}
