import Foundation

// 转录的领域模型：认得 wire 的那一层把每一帧解成这里的形状（TranscriptPayloadDecoding），
// 表现层只看这些类型。

/// 一次工具调用（线上的 tool_use_start）。
public struct ToolUse: Sendable, Equatable {
    public var id: String
    public var name: String
    /// 入参；解不出 JSON 对象时为 nil。
    public var input: [String: JSONValue]?
    /// 后端已算好的规范形态；词表外或没有时为 nil。
    public var canonical: Canonical?
    /// 这一步在哪个 Subagent 里跑（父调用的 id）；顶层为 nil。
    public var parentID: String?
    /// 后台任务 / Subagent 的运行态（由 subagent_* 帧回填）。
    public var subagent: SubagentState?

    public init(id: String, name: String, input: [String: JSONValue]? = nil, canonical: Canonical? = nil, parentID: String? = nil, subagent: SubagentState? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.canonical = canonical
        self.parentID = parentID
        self.subagent = subagent
    }
}

/// 规范形态。线上是扁平的 `{kind, ...字段}`，这里保留 kind 与其余字段。
public struct Canonical: Sendable, Equatable {
    public var kind: String
    public var fields: [String: JSONValue]

    public init(kind: String, fields: [String: JSONValue] = [:]) {
        self.kind = kind
        self.fields = fields
    }

    /// 从线上扁平形态解出；没有 kind 时为 nil。
    public init?(flat: JSONValue?) {
        guard var fields = flat?.object, let kind = fields["kind"]?.string, !kind.isEmpty else { return nil }
        fields["kind"] = nil
        self.init(kind: kind, fields: fields)
    }

    public enum Kind {
        public static let agentSpawn = "agent.spawn"
        public static let userAsk = "user.ask"
        public static let planApproveRequest = "plan.approve_request"
        public static let toolPermission = "tool.permission"
        public static let fileWrite = "file.write"
        public static let fileEdit = "file.edit"
    }

    /// file.edit：后端已按文件算好的增删行。
    public var editedFiles: [FilePatch] {
        guard kind == Kind.fileEdit else { return [] }
        return (fields["files"]?.array ?? []).compactMap { file in
            guard let path = file["path"]?.string else { return nil }
            return FilePatch(path: path, plus: file["plus"]?.int ?? 0, minus: file["minus"]?.int ?? 0)
        }
    }

    /// file.write：写入的行数。
    public var writtenLines: Int? {
        kind == Kind.fileWrite ? (fields["lines"]?.int ?? 0) : nil
    }
}

public struct FilePatch: Sendable, Equatable {
    public var path: String
    public var plus: Int
    public var minus: Int

    public init(path: String, plus: Int, minus: Int) {
        self.path = path
        self.plus = plus
        self.minus = minus
    }
}

/// 后台任务 / Subagent 的运行态（线上的 SubagentInfo）。
public struct SubagentState: Sendable, Equatable {
    public var taskID: String
    /// waiting | running | completed | partial | failed | canceled | skipped | unknown；空 = 没报过。
    public var status: String
    public var subagentType: String
    public var taskDescription: String
    /// 0 = 没报过。
    public var durationMs: Int
    public var toolUses: Int

    public init(taskID: String = "", status: String = "", subagentType: String = "", taskDescription: String = "", durationMs: Int = 0, toolUses: Int = 0) {
        self.taskID = taskID
        self.status = status
        self.subagentType = subagentType
        self.taskDescription = taskDescription
        self.durationMs = durationMs
        self.toolUses = toolUses
    }

    public var isTerminal: Bool { ["completed", "failed", "canceled"].contains(status) }
}

/// 一次工具调用的结果（线上的 tool_result）。
public struct ToolResult: Sendable, Equatable {
    public var toolCallID: String
    public var text: String
    public var isError: Bool
    public var parentID: String?

    public init(toolCallID: String, text: String, isError: Bool = false, parentID: String? = nil) {
        self.toolCallID = toolCallID
        self.text = text
        self.isError = isError
        self.parentID = parentID
    }
}

/// 待批准的工具调用。卡片本身归审批任务，这里只是数据。
public struct PermissionRequest: Sendable, Equatable {
    public var requestID: String
    public var toolCallID: String
    public var toolName: String
    public var input: [String: JSONValue]?
    public var resolved = false
    public var allowed = false

    public init(requestID: String, toolCallID: String, toolName: String, input: [String: JSONValue]? = nil) {
        self.requestID = requestID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.input = input
    }
}

/// 提问里的一个选项（线上的 AskOption）。
public struct AskOption: Sendable, Equatable {
    /// 选中后原样作为答案的 label 发回。
    public var label: String
    public var description: String

    public init(label: String, description: String = "") {
        self.label = label
        self.description = description
    }
}

/// 提问里的一问（线上的 AskQuestion）。选项之外总可以自填答案（`QuestionAnswer.otherLabel`），
/// 与宿主的提问卡片同。
public struct AskQuestion: Sendable, Equatable {
    public var id: String
    public var question: String
    /// 短标题；空 = 没给。
    public var header: String
    /// 可多选；否则单选。
    public var multiSelect: Bool
    /// 自填答案按密码输入。
    public var isSecret: Bool
    public var options: [AskOption]

    public init(id: String = "", question: String, header: String = "", multiSelect: Bool = false, isSecret: Bool = false, options: [AskOption] = []) {
        self.id = id
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.isSecret = isSecret
        self.options = options
    }
}

/// agent 的提问。
public struct QuestionRequest: Sendable, Equatable {
    public var requestID: String
    public var toolCallID: String
    public var questions: [AskQuestion]
    public var answered = false

    public init(requestID: String, toolCallID: String, questions: [AskQuestion]) {
        self.requestID = requestID
        self.toolCallID = toolCallID
        self.questions = questions
    }
}

/// 一条消息里的一块。
public enum TranscriptBlock: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    case permission(PermissionRequest)
    case question(QuestionRequest)
}

/// 转录里的一条消息。
public struct TranscriptMessage: Sendable, Equatable, Identifiable {
    public enum Role: Sendable, Equatable { case user, assistant }

    /// 开启这条消息的那一帧的锚点：向前补历史时不变。
    public let id: String
    public let role: Role
    /// 用户消息的正文。
    public var text: String
    public var blocks: [TranscriptBlock]
    /// 这一轮的耗时（终态帧带来）；0 = 没报过。
    public var durationMs: Int
    /// 这条助手消息最近一次模型调用的总输入 token；0 = 没报过。
    public var totalInputTokens: Int
    public var errorText: String

    public init(id: String, role: Role, text: String = "", blocks: [TranscriptBlock] = [], durationMs: Int = 0, totalInputTokens: Int = 0, errorText: String = "") {
        self.id = id
        self.role = role
        self.text = text
        self.blocks = blocks
        self.durationMs = durationMs
        self.totalInputTokens = totalInputTokens
        self.errorText = errorText
    }
}

/// 一段转录归约后的全貌。
public struct TranscriptDocument: Sendable, Equatable {
    public var messages: [TranscriptMessage] = []
    /// 这一轮是否还在跑。
    public var running = false
    /// 上下文窗口；0 = 还没探到。
    public var contextWindow = 0
    /// 还在流的预览尾巴（正文 / 思考）；落定后为空。
    public var liveText = ""
    public var liveThinking = ""

    public init() {}

    /// 上下文用量：窗口不为正时为 nil（整块不渲染）。
    public var contextUsage: ContextUsage? {
        ContextUsage.compute(
            messages: messages.map { ContextUsageMessage(role: $0.role == .assistant ? .assistant : .user, totalInputTokens: $0.totalInputTokens) },
            contextWindow: contextWindow
        )
    }
}

// MARK: 帧

/// 一轮结束（runtime 的 done 或 agentred 的 run_result_done）。
public struct TurnDone: Sendable, Equatable {
    public var durationMs: Int
    public var contextWindow: Int
    public var stopError: String

    public init(durationMs: Int = 0, contextWindow: Int = 0, stopError: String = "") {
        self.durationMs = durationMs
        self.contextWindow = contextWindow
        self.stopError = stopError
    }
}

/// subagent_started / progress / done。
public struct SubagentUpdate: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case started, progress, done }

    public var toolCallID: String
    public var phase: Phase
    public var info: SubagentState

    public init(toolCallID: String, phase: Phase, info: SubagentState) {
        self.toolCallID = toolCallID
        self.phase = phase
        self.info = info
    }
}

/// 一帧解出的事件。转录用不到的（会话级状态、重试、预览外的过场）一律是 `.ignored`。
public enum TranscriptEvent: Sendable, Equatable {
    case userMessage(String)
    /// 轮次在跑时插进来的那几句话：一条一条用户消息。
    case steerConsumed([String])
    case textDelta(String)
    case thinkingDelta(String)
    case toolCall(ToolUse)
    case toolResult(ToolResult)
    case permissionRequest(PermissionRequest)
    case permissionResolved(requestID: String, allowed: Bool)
    case questionRequest(QuestionRequest)
    case questionResolved(requestID: String)
    case subagent(SubagentUpdate)
    case usage(totalInputTokens: Int, contextWindow: Int)
    case contextWindow(Int)
    case turnStarted
    case turnDone(TurnDone)
    case error(String)
    case ignored
}

/// 一帧 wire 通知解出来的东西。
public struct DecodedNotification: Sendable, Equatable {
    /// 预览帧：逐片段增量与过场，不带号、不入库，被下一条持久帧取代。
    public var preview: Bool
    public var event: TranscriptEvent

    public init(preview: Bool = false, event: TranscriptEvent) {
        self.preview = preview
        self.event = event
    }
}

/// 合流之后的一帧：锚点是它在转录里的稳定身份。
public struct TimelineEntry: Sendable, Equatable {
    public var anchor: String
    public var event: TranscriptEvent
    /// 预览帧：归约成还在流的尾巴，不进消息块。
    public var preview: Bool

    public init(anchor: String, event: TranscriptEvent, preview: Bool = false) {
        self.anchor = anchor
        self.event = event
        self.preview = preview
    }
}
