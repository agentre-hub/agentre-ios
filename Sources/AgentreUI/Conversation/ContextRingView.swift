import AgentreDesign
import AgentreDomain
import SwiftUI

/// 上下文用量：一枚环加百分比。环按用量分三档变色，点开是一枚锚在环上的只读浮层。
/// 上下文窗口不为正时（`usage == nil`）整块不渲染。
public struct ContextRingView: View {
    private let usage: ContextUsage?
    @State private var showsDetail = false

    public init(usage: ContextUsage?) {
        self.usage = usage
    }

    public var body: some View {
        if let usage {
            Button {
                showsDetail.toggle()
            } label: {
                HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .stroke(.token(.surface2), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: usage.fraction)
                            .stroke(.token(Self.token(for: usage.level)), style: StrokeStyle(lineWidth: 2.5, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                    Text("context.percent \(usage.percent)", tableName: "Conversation", bundle: .module)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.token(usage.level == .ok ? .textSecondary : Self.token(for: usage.level)))
                }
            }
            .hitTarget()
            .popover(isPresented: $showsDetail) {
                ContextUsageDetail(usage: usage)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    /// 三档：正常取 accent、告警取 waiting、危急取 failure。
    static func token(for level: UsageLevel) -> ColorToken {
        switch level {
        case .ok: .accent
        case .warn: .waiting
        case .danger: .failure
        }
    }
}

/// 上下文浮层：只给已用与上限的绝对值，不承载任何动作入口，也不解释上限从哪来。
public struct ContextUsageDetail: View {
    private let usage: ContextUsage

    public init(usage: ContextUsage) {
        self.usage = usage
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("context.used", tableName: "Conversation", bundle: .module)
                    .foregroundStyle(.token(.textSecondary))
                Text(verbatim: usage.used.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.token(.textPrimary))
                    .gridColumnAlignment(.trailing)
            }
            GridRow {
                Text("context.max", tableName: "Conversation", bundle: .module)
                    .foregroundStyle(.token(.textSecondary))
                Text(verbatim: usage.max.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.token(.textPrimary))
            }
        }
        .font(.footnote)
        .padding(14)
    }
}
