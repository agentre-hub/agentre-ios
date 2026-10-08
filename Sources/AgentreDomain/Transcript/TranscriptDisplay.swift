import Foundation

// 对话屏上的显示取值（规格「逐屏视觉契约·02 对话」）：日期胶囊的分日、耗时的「分:秒」、
// 回复署名里后端的显示名、导航栏副标题取的状态。

/// 日期胶囊写哪一种：「今天 9:32」「昨天 9:32」，或日期加时刻。
public enum CapsuleDay: Sendable, Equatable {
    case today, yesterday, earlier

    /// 按本机日历的自然日判，不按 24 小时算。比本机此刻还晚（源端时钟快）的写日期。
    public static func of(_ date: Date, now: Date, calendar: Calendar) -> CapsuleDay {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        return .earlier
    }
}

/// 组头与 Subagent 的耗时：「分:秒」，秒补足两位，分钟不封顶。
public enum ClockDuration {
    /// 不足一秒的正数记一秒：一轮跑过了，不写成 0:00。
    public static func text(milliseconds: Int) -> String {
        let seconds = milliseconds > 0 ? max(1, Int((Double(milliseconds) / 1000).rounded())) : 0
        let tail = seconds % 60
        return "\(seconds / 60):\(tail < 10 ? "0" : "")\(tail)"
    }
}

/// 后端的显示名：宿主的 shortLabel（agentre-ui 的 llm.json agentBackends.backendType.*.shortLabel，
/// 两种语言同形），表外取值原样。
public enum BackendLabel {
    private static let shortLabels = [
        "claudecode": "Claude Code",
        "codex": "Codex",
        "hermes": "Hermes",
        "piagent": "Pi Agent",
    ]

    public static func short(_ backendType: String) -> String {
        shortLabels[backendType] ?? backendType
    }
}

extension TranscriptDocument {
    /// 导航栏副标题取的状态：这一轮在跑且停在一张没处置的审批或提问上为等你回复，只在跑为正在输入，其余为空闲。
    /// 只看这一轮（最后一条助手消息）：一轮已收场还挂着的请求不再有人等。
    public var activity: ConversationActivity {
        guard running else { return .idle }
        let turn = messages.last { $0.role == .assistant }?.blocks ?? []
        let waiting = turn.contains { block in
            switch block {
            case .permission(let request): !request.resolved
            case .question(let request): !request.answered
            default: false
            }
        }
        return waiting ? .waiting : .typing
    }
}
