import Foundation

/// 工具调用落的视觉档。出组档（审批 / 提问 / 计划审批 / Subagent 派生）不进活动块。
public enum ToolTier: Sendable, Equatable { case out, write, read, neutral }

/// 比档细一级：活动块组头把写层再分「改文件 / 写入 / 命令」。
public enum ToolCategory: Sendable, Equatable { case read, edit, write, command, other }

/// 组头汇总的类目，声明顺序即固定输出顺序。
public enum ActivityCategory: Sendable, Equatable, CaseIterable {
    case thinking, read, edit, write, command, other
}

/// 活动块里的一步：一段已落定的思考，或一次工具调用（连同配上的结果）。
public enum ActivityStep: Sendable, Equatable, Identifiable {
    case thinking(key: String, text: String)
    case tool(key: String, use: ToolUse, result: ToolResult?)

    public var id: String {
        switch self {
        case .thinking(let key, _), .tool(let key, _, _): key
        }
    }

    public var toolUse: ToolUse? {
        if case .tool(_, let use, _) = self { return use }
        return nil
    }

    public var toolResult: ToolResult? {
        if case .tool(_, _, let result) = self { return result }
        return nil
    }
}

public struct ActivitySummaryPart: Sendable, Equatable {
    public var category: ActivityCategory
    /// 本类目的步数。
    public var count: Int
    /// 仅改文件：改到的文件数（同一路径算一个）与增删行合计。
    public var files: Int?
    public var plus: Int?
    public var minus: Int?

    public init(category: ActivityCategory, count: Int, files: Int? = nil, plus: Int? = nil, minus: Int? = nil) {
        self.category = category
        self.count = count
        self.files = files
        self.plus = plus
        self.minus = minus
    }
}

public struct ActivitySummary: Sendable, Equatable {
    /// 组内步数。
    public var steps: Int
    /// 固定顺序、已截断到 `ActivityRules.summaryMaxParts` 的类目汇总。
    public var parts: [ActivitySummaryPart]
    /// 还有类目没进 parts：组头在末尾补省略号。
    public var truncated: Bool
    /// 失败步数。永不参与截断。
    public var failures: Int
    /// 此刻还在后台跑的步数。与失败同规矩：单列、永不参与截断。
    public var backgroundRunning: Int

    public init(steps: Int = 0, parts: [ActivitySummaryPart] = [], truncated: Bool = false, failures: Int = 0, backgroundRunning: Int = 0) {
        self.steps = steps
        self.parts = parts
        self.truncated = truncated
        self.failures = failures
        self.backgroundRunning = backgroundRunning
    }
}

/// 一段连续活动折成的块。
public struct ActivityGroup: Sendable, Equatable {
    /// 取首步身份：流式生长中不漂移。
    public var key: String
    public var steps: [ActivityStep]
    public var summary: ActivitySummary
    /// 后面只跟着一段还在流的思考（它一落定就并回来）：判「此刻在跑」时要算上。
    public var growing: Bool

    public init(key: String, steps: [ActivityStep], summary: ActivitySummary, growing: Bool = false) {
        self.key = key
        self.steps = steps
        self.summary = summary
        self.growing = growing
    }
}

/// Subagent 派生：嵌套的另一个执行体，它的内层步骤归它自己。
public struct SubagentGroup: Sendable, Equatable {
    public var key: String
    public var use: ToolUse
    public var result: ToolResult?
    public var steps: [ActivityStep]

    public init(key: String, use: ToolUse, result: ToolResult?, steps: [ActivityStep]) {
        self.key = key
        self.use = use
        self.result = result
        self.steps = steps
    }
}

/// 转录里需要单独处理的卡片（审批、提问、计划审批）。卡片视图归审批任务。
public enum TranscriptCard: Sendable, Equatable {
    case permission(PermissionRequest)
    case question(QuestionRequest)
    /// 带出组 canonical 的工具调用（计划审批、提问、工具权限）。
    case tool(ToolUse, ToolResult?)
}

/// 一条助手消息里的渲染项：正文 / 活动块 / 出组卡片。
public enum TranscriptItem: Sendable, Equatable {
    case text(key: String, text: String, streaming: Bool)
    /// 还在流的思考（不进组）。
    case thinking(key: String, text: String, streaming: Bool)
    case activity(ActivityGroup)
    case subagent(SubagentGroup)
    case card(key: String, TranscriptCard)
}

// MARK: 一步的事实

/// 没有结果的一步按什么归属报。
public enum PendingOutcome: Sendable, Equatable { case running, failed, canceled, unknown }

/// 三档视觉权重。
public enum ActivityWeight: Sendable, Equatable { case neutral, read, write }

/// 一步执行完之后可报出来的事实；空值表示「这一步没有这项事实」。
public struct StepFacts: Sendable, Equatable {
    /// 失败：与组头失败计数同一判据（结果错误标志或命令退出码 / 状态）。
    public var failed = false
    /// 没有结果时的归属；有结果就是 nil。
    public var pending: PendingOutcome?
    public var backgroundRunning = false
    public var backgroundTaskID: String?
    /// 非零退出码。
    public var exitCode: Int?
    /// 行尾写的结果；没有结构化结果（成功命令的原文、认不出的工具、运行中）时为 nil。
    public var result: StepResult?
    /// 展开体要渲染的结果正文（命令结果取 output）。
    public var resultText = ""

    public init() {}
}

/// 一步在行尾写的结果，按工具种类取（规格「02 对话」：搜索类「N 处」，读文件「N 行」，改文件「+N」，失败写「失败」）。
public enum StepResult: Sendable, Equatable {
    /// 搜索形状（入参带 pattern / query）：结果的非空行数。
    case matches(Int)
    /// 读文件形状（入参带路径）：结果的行数。
    case lines(Int)
    /// 改文件 / 写入：后端已算好的增删行。
    case changed(plus: Int, minus: Int)
    case failed
}

/// 一步在行首怎么称呼自己。
public struct StepLabel: Sendable, Equatable {
    /// shell 形态统一叫 Bash；MCP 拆成「server · tool」。
    public var name: String
    public var summary: String
    /// 仅多文件改动：改到几个文件（文案在表现层）。
    public var fileCount: Int?

    public init(name: String, summary: String, fileCount: Int? = nil) {
        self.name = name
        self.summary = summary
        self.fileCount = fileCount
    }
}

/// 一个活动块此刻该怎么摆。
public struct ActivityBlockLayout: Sendable, Equatable {
    /// 只有一步时不出组头，直接是那一行。
    public var showsHeader: Bool
    public var expanded: Bool
    /// 运行中被省略的前几步。
    public var elidedCount: Int
    /// 组头耗时；运行中恒为 nil。
    public var durationMs: Int?

    public init(showsHeader: Bool, expanded: Bool, elidedCount: Int, durationMs: Int?) {
        self.showsHeader = showsHeader
        self.expanded = expanded
        self.elidedCount = elidedCount
        self.durationMs = durationMs
    }
}

/// 用户的展开选择。自动行为（运行中展开、落定收起）只作用于没被碰过的块。
public struct TranscriptDisclosure: Sendable, Equatable {
    public var expanded: [String: Bool] = [:]
    public var showAllSteps: Set<String> = []

    public init() {}

    public mutating func toggle(_ key: String, current: Bool) {
        expanded[key] = !current
    }

    public mutating func showAll(_ key: String) {
        showAllSteps.insert(key)
    }
}

/// 自动跟随：上滚即停，其间新增按行计数。
public struct TranscriptFollow: Sendable, Equatable {
    public internal(set) var isFollowing = true
    public internal(set) var unseen = 0

    public init() {}
}
