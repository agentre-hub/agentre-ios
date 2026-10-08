import AgentreDomain
import Testing

/// 帧 → 消息：一轮的正文、工具与卡片归进同一条助手消息；决议回填原卡。
@Suite("帧归约")
struct ReducerTests {
    func entries(_ events: [TranscriptEvent]) -> [TimelineEntry] {
        events.enumerated().map { TimelineEntry(anchor: "s\($0.offset + 1)", event: $0.element) }
    }

    @Test("用户消息开一条右侧气泡；随后的正文、思考、工具进同一条助手消息，消息以开启它的那一帧定身份")
    func messages() {
        let doc = TranscriptReducer.reduce(entries([
            .userMessage("修构建"), .turnStarted, .thinkingDelta("先看"), .thinkingDelta("日志"), .textDelta("好的"),
            .toolCall(use("t1")), .toolResult(result("t1")), .textDelta("修好了"),
            .turnDone(TurnDone(durationMs: 6600, contextWindow: 200_000)),
        ]))
        #expect(doc.messages.map(\.role) == [.user, .assistant])
        #expect(doc.messages[0].text == "修构建")
        #expect(doc.messages[1].id == "s3")
        #expect(doc.messages[1].blocks == [.thinking("先看日志"), .text("好的"), .toolUse(use("t1")), .toolResult(result("t1")), .text("修好了")])
        #expect(doc.messages[1].durationMs == 6600)
        #expect(!doc.running)
        #expect(doc.contextWindow == 200_000)
    }

    @Test("轮次开始即运行中，结束即落定；没见过边界时沿用会话的生命周期")
    func running() {
        #expect(TranscriptReducer.reduce(entries([.userMessage("a"), .turnStarted, .textDelta("x")])).running)
        #expect(!TranscriptReducer.reduce(entries([.userMessage("a"), .textDelta("x"), .turnDone(TurnDone())])).running)
        #expect(TranscriptReducer.reduce(entries([.textDelta("x")]), initiallyRunning: true).running)
        #expect(!TranscriptReducer.reduce(entries([.textDelta("x")]), initiallyRunning: false).running)
    }

    @Test("审批与提问的决议回填原卡，而不是新起一条")
    func resolutionsFillBack() {
        let doc = TranscriptReducer.reduce(entries([
            .permissionRequest(PermissionRequest(requestID: "r1", toolCallID: "t1", toolName: "Bash")),
            .permissionResolved(requestID: "r1", allowed: true),
            .questionRequest(QuestionRequest(requestID: "q1", toolCallID: "", questions: [AskQuestion(question: "?")])),
            .questionResolved(requestID: "q1"),
        ]))
        var permission = PermissionRequest(requestID: "r1", toolCallID: "t1", toolName: "Bash")
        permission.resolved = true
        permission.allowed = true
        var question = QuestionRequest(requestID: "q1", toolCallID: "", questions: [AskQuestion(question: "?")])
        question.answered = true
        #expect(doc.messages.single?.blocks == [.permission(permission), .question(question)])
    }

    @Test("权限决议带着「本会话始终允许」回填原卡")
    func permissionResolutionCarriesAlwaysAllow() {
        let doc = TranscriptReducer.reduce(entries([
            .permissionRequest(PermissionRequest(requestID: "r1", toolCallID: "t1", toolName: "Bash")),
            .permissionResolved(requestID: "r1", allowed: true, alwaysAllow: true),
        ]))
        guard case .permission(let request) = doc.messages.single?.blocks.first else { Issue.record("no card"); return }
        #expect(request.resolved && request.allowed && request.alwaysAllow)
    }

    @Test("提问带着选项、单选 / 多选与标题原样进卡片，决议只改作答位")
    func questionOptionsSurvive() {
        let asked = QuestionRequest(requestID: "q1", toolCallID: "t1", questions: [
            AskQuestion(id: "branch", question: "用哪个分支？", header: "分支", options: [AskOption(label: "main", description: "主干"), AskOption(label: "dev")]),
            AskQuestion(question: "跑哪些检查？", multiSelect: true, isSecret: false, options: [AskOption(label: "lint"), AskOption(label: "test")]),
        ])
        let open = TranscriptReducer.reduce(entries([.questionRequest(asked)]))
        #expect(open.messages.single?.blocks == [.question(asked)])
        let resolved = TranscriptReducer.reduce(entries([.questionRequest(asked), .questionResolved(requestID: "q1")]))
        var answered = asked
        answered.answered = true
        #expect(resolved.messages.single?.blocks == [.question(answered)])
    }

    @Test("Subagent 的开始 / 进度 / 结束落到派生它的那次调用上")
    func subagentState() {
        let spawn = use("sp", "Task", input: ["prompt": "go"], canonical: Canonical(kind: "agent.spawn"))
        let doc = TranscriptReducer.reduce(entries([
            .toolCall(spawn),
            .subagent(SubagentUpdate(toolCallID: "sp", phase: .started, info: SubagentState(taskID: "task-1", status: ""))),
            .subagent(SubagentUpdate(toolCallID: "sp", phase: .done, info: SubagentState(taskID: "task-1", status: "", durationMs: 4200))),
        ]))
        guard case .toolUse(let tool) = doc.messages.single?.blocks.first else { Issue.record("no tool"); return }
        #expect(tool.subagent?.status == "completed")
        #expect(tool.subagent?.durationMs == 4200)
    }

    @Test("一轮收尾时还挂在运行中的前台 Subagent 翻成已取消，不会永远转下去")
    func turnEndCancelsForegroundSubagents() {
        let spawn = use("sp", "Task", input: ["prompt": "go"], canonical: Canonical(kind: "agent.spawn"))
        let doc = TranscriptReducer.reduce(entries([
            .toolCall(spawn),
            .subagent(SubagentUpdate(toolCallID: "sp", phase: .started, info: SubagentState(taskID: "task-1", status: "running"))),
            .turnDone(TurnDone(stopError: "interrupted")),
        ]))
        guard case .toolUse(let tool) = doc.messages.single?.blocks.first else { Issue.record("no tool"); return }
        #expect(tool.subagent?.status == "canceled")
    }

    @Test("后台任务可以活过发起它的那一轮：默认后台的 Agent 与 run_in_background 的 Bash 收尾时不翻；显式前台的 Agent 照翻", arguments: [
        ("local_agent", nil, "running"),
        ("local_agent", false, "canceled"),
        ("local_bash", true, "running"),
    ] as [(String, Bool?, String)])
    func backgroundSubagentsOutliveTheTurn(kind: String, background: Bool?, settled: String) {
        var input: [String: JSONValue] = ["prompt": "go"]
        if let background { input["run_in_background"] = .bool(background) }
        let doc = TranscriptReducer.reduce(entries([
            .toolCall(use("sp", "Task", input: input)),
            .subagent(SubagentUpdate(toolCallID: "sp", phase: .started, info: SubagentState(taskID: "task-1", status: "running", kind: kind))),
            .turnDone(TurnDone()),
        ]))
        guard case .toolUse(let tool) = doc.messages.single?.blocks.first else { Issue.record("no tool"); return }
        #expect(tool.subagent?.status == settled)
    }

    @Test("前台 Bash 的 local_bash 帧不挂 Subagent 状态；没挂过的调用，进度与结束也不补挂（宿主 frames.ts 同一规矩）")
    func foregroundBashGetsNoSubagent() {
        let doc = TranscriptReducer.reduce(entries([
            .toolCall(use("b", "Bash", input: ["command": "ls"])),
            .subagent(SubagentUpdate(toolCallID: "b", phase: .started, info: SubagentState(taskID: "task-b", status: "running", kind: "local_bash"))),
            .toolCall(use("r", "Read", input: ["path": "a"])),
            .subagent(SubagentUpdate(toolCallID: "r", phase: .progress, info: SubagentState(status: "running"))),
            .subagent(SubagentUpdate(toolCallID: "r", phase: .done, info: SubagentState(status: "completed"))),
            .turnDone(TurnDone()),
        ]))
        let tools = doc.messages.single?.blocks.compactMap { block -> ToolUse? in
            if case .toolUse(let use) = block { use } else { nil }
        } ?? []
        #expect(tools.map(\.id) == ["b", "r"])
        #expect(tools.allSatisfy { $0.subagent == nil }, "\(tools.map(\.subagent))")
    }

    @Test("用量：助手消息记下总输入、窗口记到转录上，二者得出上下文用量；错误落到这一轮")
    func usageAndErrors() {
        let doc = TranscriptReducer.reduce(entries([
            .userMessage("a"), .textDelta("x"), .usage(totalInputTokens: 1200, contextWindow: 10_000), .error("boom"),
        ]))
        #expect(doc.messages[1].totalInputTokens == 1200)
        #expect(doc.contextWindow == 10_000)
        #expect(doc.messages[1].errorText == "boom")
        #expect(doc.contextUsage == ContextUsage(used: 1200, max: 10_000))
    }

    @Test("上下文窗口未知时没有用量")
    func noWindowNoUsage() {
        #expect(TranscriptReducer.reduce(entries([.userMessage("a"), .usage(totalInputTokens: 5, contextWindow: 0)])).contextUsage == nil)
    }
}

extension Array {
    var single: Element? { count == 1 ? first : nil }
}
