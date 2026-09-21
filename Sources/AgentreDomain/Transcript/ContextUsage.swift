import Foundation

// 上下文用量的取值与定档，移植自宿主 agentre-ui 的 composer/context-usage.ts 与 usage-level.ts。

extension ContextUsage {
    /// - 窗口不为正：nil（整块不渲染，而不是渲染成零）；
    /// - 流式用量为正时优先；
    /// - 否则从尾部往前找首条总输入为正的助手消息；
    /// - 都没有：0 / 上限的占位。
    public static func compute(messages: [ContextUsageMessage], contextWindow: Int, liveTotalInputTokens: Int? = nil) -> ContextUsage? {
        guard contextWindow > 0 else { return nil }
        if let live = liveTotalInputTokens, live > 0 { return ContextUsage(used: live, max: contextWindow) }
        let used = messages.last { $0.role == .assistant && ($0.totalInputTokens ?? 0) > 0 }?.totalInputTokens ?? 0
        return ContextUsage(used: used, max: contextWindow)
    }

    /// 已用比例，封在 0…1；负的已用按 0。
    public var fraction: Double {
        guard max > 0 else { return 0 }
        return Swift.min(1, Double(Swift.max(0, used)) / Double(max))
    }

    /// 显示用的整数百分比。
    public var percent: Int { Int((fraction * 100).rounded()) }

    /// 按比例定档，不按取整后的百分比：89.5% 仍是告警。
    public var level: UsageLevel { UsageLevel(percent: fraction * 100) }
}

extension UsageLevel {
    /// 告警阈值的唯一来源：≥90 危急、≥75 告警；空值不告警。
    public init(percent: Double?) {
        guard let percent else { self = .ok; return }
        if percent >= 90 {
            self = .danger
        } else if percent >= 75 {
            self = .warn
        } else {
            self = .ok
        }
    }
}
