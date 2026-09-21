import Foundation

/// 转录的一行。可点的元素各占一行：组头、步骤、省略行、Subagent。
public struct TranscriptRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let content: Content

    public init(id: String, content: Content) {
        self.id = id
        self.content = content
    }

    public enum Content: Sendable, Equatable {
        /// 用户消息：右侧气泡。
        case user(String)
        /// 助手消息的首行：头像与署名。
        case agentHeader
        case text(String, streaming: Bool)
        /// 还在流的思考。
        case thinking(String)
        case activityHeader(ActivityHeaderRow)
        case step(StepRow)
        /// 点开的那一步的参数与结果。
        case stepDetail(StepRow)
        case elided(ElidedRow)
        case subagent(SubagentRow)
        /// 审批 / 提问 / 计划审批：卡片视图由审批任务插入。
        case card(TranscriptCard)
        /// 这一轮的错误原话；空串 = 没带原话，界面给出通用的一句。
        case error(String)
    }
}

public struct ActivityHeaderRow: Sendable, Equatable {
    public var blockKey: String
    public var summary: ActivitySummary
    public var running: Bool
    public var expanded: Bool
    /// 运行中恒为 nil。
    public var durationMs: Int?
    /// 嵌套深度：Subagent 内层为 1。
    public var depth: Int

    public init(blockKey: String, summary: ActivitySummary, running: Bool, expanded: Bool, durationMs: Int?, depth: Int) {
        self.blockKey = blockKey
        self.summary = summary
        self.running = running
        self.expanded = expanded
        self.durationMs = durationMs
        self.depth = depth
    }
}

public struct StepRow: Sendable, Equatable {
    public var key: String
    public var step: ActivityStep
    public var facts: StepFacts
    public var label: StepLabel
    public var weight: ActivityWeight
    public var category: ToolCategory?
    public var depth: Int
    /// 上面没有组头：展开指示常显。
    public var standalone: Bool
    public var expanded: Bool

    public init(key: String, step: ActivityStep, facts: StepFacts, label: StepLabel, weight: ActivityWeight, category: ToolCategory?, depth: Int, standalone: Bool, expanded: Bool) {
        self.key = key
        self.step = step
        self.facts = facts
        self.label = label
        self.weight = weight
        self.category = category
        self.depth = depth
        self.standalone = standalone
        self.expanded = expanded
    }
}

public struct ElidedRow: Sendable, Equatable {
    public var blockKey: String
    public var count: Int
    /// 被省略部分的汇总与失败数。
    public var summary: ActivitySummary
    public var depth: Int

    public init(blockKey: String, count: Int, summary: ActivitySummary, depth: Int) {
        self.blockKey = blockKey
        self.count = count
        self.summary = summary
        self.depth = depth
    }
}

/// Subagent 折叠态的那一行：名称、步数、耗时——不带工具分类汇总。
public struct SubagentRow: Sendable, Equatable {
    public var key: String
    public var name: String
    public var stepCount: Int
    /// 运行中恒为 nil。
    public var durationMs: Int?
    public var running: Bool
    public var failed: Bool
    public var expanded: Bool

    public init(key: String, name: String, stepCount: Int, durationMs: Int?, running: Bool, failed: Bool, expanded: Bool) {
        self.key = key
        self.name = name
        self.stepCount = stepCount
        self.durationMs = durationMs
        self.running = running
        self.failed = failed
        self.expanded = expanded
    }
}

// MARK: 上下文用量

/// 用量三档：正常 / 告警 / 危急。
public enum UsageLevel: Sendable, Equatable {
    case ok, warn, danger
}

public struct ContextUsage: Sendable, Equatable {
    public var used: Int
    public var max: Int

    public init(used: Int, max: Int) {
        self.used = used
        self.max = max
    }
}
