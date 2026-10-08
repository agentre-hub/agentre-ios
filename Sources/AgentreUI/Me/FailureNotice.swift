import AgentreDesign
import AgentreDomain
import SwiftUI

/// 错误呈现层：一个失败事实在屏上的样子——一枚图标、一句以用户语言重述的事实，
/// 有出口时再给一个出口。它只收 `FailureFact`，手里没有错误对象，也就没有错误码或对端原串可显示。
public struct FailureNotice: View {
    private let fact: FailureFact
    private let onRetry: () -> Void

    public init(fact: FailureFact, onRetry: @escaping () -> Void) {
        self.fact = fact
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.token(.coral))
                .accessibilityHidden(true)
            Text(LocalizedStringKey(failureKey(fact)), tableName: "Me", bundle: .module)
                .font(.agentre(.subheadline))
                .foregroundStyle(.token(.ink))
                .frame(maxWidth: .infinity, alignment: .leading)
            if fact.exit == .retry {
                Button(action: onRetry) {
                    Text("me.retry", tableName: "Me", bundle: .module)
                        .font(.agentre(.subheadline, weight: .semibold))
                        .foregroundStyle(.token(.primary))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
            }
        }
    }

    private var symbol: String {
        switch fact {
        case .offline, .serverUnreachable: "wifi.exclamationmark"
        case .timedOut: "clock.badge.exclamationmark"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .noMachineAvailable: "desktopcomputer.trianglebadge.exclamationmark"
        case .updateRequired: "arrow.down.app"
        case .notPermitted, .revokeNeedsConsole: "hand.raised"
        case .serverUnavailable, .unrecognisedResponse, .unknown: "exclamationmark.circle"
        }
    }
}

/// 事实在 Me.xcstrings 里的键。穷举：新增一个事实而不给它一句话是编译错误。
func failureKey(_ fact: FailureFact) -> String {
    switch fact {
    case .offline: "failure.offline"
    case .serverUnreachable: "failure.serverUnreachable"
    case .timedOut: "failure.timedOut"
    case .signedOut: "failure.signedOut"
    case .notPermitted: "failure.notPermitted"
    case .revokeNeedsConsole: "failure.revokeNeedsConsole"
    case .serverUnavailable: "failure.serverUnavailable"
    case .unrecognisedResponse: "failure.unrecognisedResponse"
    case .updateRequired: "failure.updateRequired"
    case .unknown: "failure.unknown"
    case .noMachineAvailable(let reason):
        switch reason {
        case .offline: "failure.noMachine.offline"
        case .unpaired: "failure.noMachine.unpaired"
        }
    }
}
