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
            .questionRequest(QuestionRequest(requestID: "q1", toolCallID: "", questions: ["?"])),
            .questionResolved(requestID: "q1"),
        ]))
        var permission = PermissionRequest(requestID: "r1", toolCallID: "t1", toolName: "Bash")
        permission.resolved = true
        permission.allowed = true
        var question = QuestionRequest(requestID: "q1", toolCallID: "", questions: ["?"])
        question.answered = true
        #expect(doc.messages.single?.blocks == [.permission(permission), .question(question)])
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

    @Test("用量：助手消息记下总输入，流式用量另记；错误落到这一轮")
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
