import AgentreDomain
import Testing

/// 运行态与省略：逐条移植宿主 activity-block/block.tsx 的规则（RUNNING_ELIDE_OVER = 8、
/// RUNNING_TAIL = 6）与 block.test.tsx 里「运行态」「步数过多时省略」的用例。
@Suite("活动块运行态与省略")
struct ActivityDisclosureTests {
    @Test("运行中：自动展开，不出耗时")
    func runningExpandsWithoutDuration() {
        let layout = ActivityDisclosure.layout(stepCount: 2, running: true, durationMs: 6600)
        #expect(layout.showsHeader)
        #expect(layout.expanded)
        #expect(layout.durationMs == nil)
    }

    @Test("轮次落定：没被用户碰过的块自动收起，并报耗时")
    func settledCollapsesWithDuration() {
        let layout = ActivityDisclosure.layout(stepCount: 2, running: false, durationMs: 6600)
        #expect(!layout.expanded)
        #expect(layout.durationMs == 6600)
        #expect(ActivityDisclosure.layout(stepCount: 2, running: false, durationMs: 0).durationMs == nil)
    }

    @Test("用户在运行中手动收起，落定后仍按用户的选择；落定后用户点开则保持展开")
    func userChoiceWins() {
        #expect(!ActivityDisclosure.layout(stepCount: 2, running: true, userExpanded: false).expanded)
        #expect(!ActivityDisclosure.layout(stepCount: 2, running: false, userExpanded: false).expanded)
        #expect(ActivityDisclosure.layout(stepCount: 2, running: false, userExpanded: true).expanded)
    }

    @Test("调用方给了默认展开：落定态也展开，用户仍可收起")
    func defaultExpanded() {
        #expect(ActivityDisclosure.layout(stepCount: 2, running: false, defaultExpanded: true).expanded)
        #expect(!ActivityDisclosure.layout(stepCount: 2, running: false, defaultExpanded: true, userExpanded: false).expanded)
    }

    @Test("运行中且 24 步：只留最后 6 行，前 18 步收成一行")
    func elidesWhileRunning() {
        #expect(ActivityDisclosure.runningElideOver == 8)
        #expect(ActivityDisclosure.runningTail == 6)
        #expect(ActivityDisclosure.layout(stepCount: 24, running: true).elidedCount == 18)
    }

    @Test("用户点省略行后全部摊开")
    func showAll() {
        #expect(ActivityDisclosure.layout(stepCount: 24, running: true, userShowAll: true).elidedCount == 0)
    }

    @Test("运行中但只有 8 步（不过阈值）：不省略；9 步开始省略")
    func threshold() {
        #expect(ActivityDisclosure.layout(stepCount: 8, running: true).elidedCount == 0)
        #expect(ActivityDisclosure.layout(stepCount: 9, running: true).elidedCount == 3)
    }

    @Test("落定的 24 步，用户点开组头：全部都在（省略只在运行态）")
    func noElisionWhenSettled() {
        let layout = ActivityDisclosure.layout(stepCount: 24, running: false, userExpanded: true)
        #expect(layout.expanded)
        #expect(layout.elidedCount == 0)
    }

    @Test("单条不成组：只有一步时不出组头，运行中也一样")
    func singleStep() {
        #expect(!ActivityDisclosure.layout(stepCount: 1, running: false).showsHeader)
        #expect(!ActivityDisclosure.layout(stepCount: 1, running: true).showsHeader)
    }
}

/// 转录的行：一个可点元素一行，规则全部落在纯函数里。
@Suite("转录行")
struct TranscriptRowsTests {
    func document(_ blocks: [TranscriptBlock], running: Bool, durationMs: Int = 0) -> TranscriptDocument {
        var doc = TranscriptDocument()
        doc.messages = [
            TranscriptMessage(id: "u1", role: .user, text: "修一下构建"),
            TranscriptMessage(id: "a1", role: .assistant, blocks: blocks, durationMs: durationMs),
        ]
        doc.running = running
        return doc
    }

    func blocks(_ steps: [ActivityStep]) -> [TranscriptBlock] {
        steps.flatMap { step -> [TranscriptBlock] in
            switch step {
            case .thinking(_, let text): [.thinking(text)]
            case .tool(_, let use, let result): [.toolUse(use)] + (result.map { [.toolResult($0)] } ?? [])
            }
        }
    }

    func names(_ rows: [TranscriptRow]) -> [String] {
        rows.map { row in
            switch row.content {
            case .user: "user"
            case .agentHeader: "agent"
            case .text: "text"
            case .thinking: "thinking"
            case .activityHeader(let h): h.running ? "header:running" : (h.expanded ? "header:open" : "header")
            case .step(let s): s.standalone ? "step:standalone" : "step"
            case .stepDetail: "detail"
            case .elided(let e): "elided:\(e.count)"
            case .subagent: "subagent"
            case .card: "card"
            case .error: "error"
            }
        }
    }

    @Test("运行中的末块：自动展开、组头不报耗时、24 步只挂最后 6 行加一行带汇总与红失败数的省略行")
    func runningBlockRows() throws {
        let rows = TranscriptRows.build(document(blocks(manySteps(24)), running: true, durationMs: 6600))
        #expect(names(rows) == ["user", "agent", "header:running", "elided:18"] + Array(repeating: "step", count: 6))
        guard case .activityHeader(let header) = rows[2].content, case .elided(let elided) = rows[3].content else { return }
        #expect(header.durationMs == nil)
        #expect(header.summary.steps == 24)
        #expect(elided.summary.parts == [ActivitySummaryPart(category: .read, count: 15), ActivitySummaryPart(category: .command, count: 3)])
        #expect(elided.summary.failures == 3)
        guard case .step(let last) = rows.last?.content else { return }
        #expect(last.label.summary == "/repo/f-23.go")
    }

    @Test("轮次落定：同一块自动收起、报耗时；用户点开后 24 行全在")
    func settledBlockRows() {
        let doc = document(blocks(manySteps(24)), running: false, durationMs: 6600)
        let rows = TranscriptRows.build(doc)
        #expect(names(rows) == ["user", "agent", "header"])
        guard case .activityHeader(let header) = rows[2].content else { return }
        #expect(header.durationMs == 6600)
        #expect(header.summary.failures == 4)

        var disclosure = TranscriptDisclosure()
        disclosure.toggle(header.blockKey, current: header.expanded)
        let opened = TranscriptRows.build(doc, disclosure: disclosure)
        #expect(names(opened) == ["user", "agent", "header:open"] + Array(repeating: "step", count: 24))
    }

    @Test("运行中点省略行：全部摊开")
    func showAllRows() {
        let doc = document(blocks(manySteps(24)), running: true)
        guard case .elided(let elided) = TranscriptRows.build(doc)[3].content else { Issue.record("no elided row"); return }
        var disclosure = TranscriptDisclosure()
        disclosure.showAll(elided.blockKey)
        #expect(names(TranscriptRows.build(doc, disclosure: disclosure)).filter { $0 == "step" }.count == 24)
    }

    @Test("只有末块算运行中：被正文隔开的前一块已经落定")
    func onlyTheTailRuns() {
        let doc = document([.toolUse(readUse("a")), .toolUse(readUse("b")), .text("看完了"), .toolUse(readUse("c")), .toolUse(readUse("d"))], running: true)
        #expect(names(TranscriptRows.build(doc)) == ["user", "agent", "header", "text", "header:running", "step", "step"])
    }

    @Test("点开一行步骤：就地多出一行详情")
    func stepDetail() {
        let doc = document([.toolUse(readUse("a")), .toolResult(result("a", "package chat"))], running: false)
        let rows = TranscriptRows.build(doc)
        #expect(names(rows) == ["user", "agent", "step:standalone"])
        guard case .step(let step) = rows[2].content else { return }
        var disclosure = TranscriptDisclosure()
        disclosure.toggle(step.key, current: step.expanded)
        #expect(names(TranscriptRows.build(doc, disclosure: disclosure)) == ["user", "agent", "step:standalone", "detail"])
    }

    @Test("Subagent 折叠态只占一行：名称、步数、耗时，不带工具分类汇总；展开后由它自己的活动块给出汇总")
    func subagentOneLine() throws {
        let spawn = use("sp", "Task", input: ["prompt": "go"], canonical: Canonical(kind: "agent.spawn", fields: ["taskDescription": "查日志"]),
                        subagent: SubagentState(taskID: "task-1", status: "completed", durationMs: 12_300))
        var blocks: [TranscriptBlock] = [.toolUse(spawn)]
        for i in 0..<3 {
            blocks.append(.toolUse(use("c\(i)", input: ["command": "ls"], parent: "sp")))
            blocks.append(.toolResult(ToolResult(toolCallID: "c\(i)", text: "ok", isError: false, parentID: "sp")))
        }
        blocks.append(.toolResult(result("sp", "done")))
        let doc = document(blocks, running: false)
        let rows = TranscriptRows.build(doc)
        #expect(names(rows) == ["user", "agent", "subagent"])
        guard case .subagent(let sub) = rows[2].content else { return }
        #expect(sub.name == "查日志")
        #expect(sub.stepCount == 3)
        #expect(sub.durationMs == 12_300)
        #expect(!sub.expanded)

        var disclosure = TranscriptDisclosure()
        disclosure.toggle(sub.key, current: sub.expanded)
        let opened = TranscriptRows.build(doc, disclosure: disclosure)
        #expect(names(opened) == ["user", "agent", "subagent", "header:open", "step", "step", "step"])
        guard case .activityHeader(let inner) = opened[3].content, case .step(let child) = opened[4].content else { return }
        #expect(inner.summary.parts == [ActivitySummaryPart(category: .command, count: 3)])
        #expect(inner.depth == 1)
        #expect(child.depth == 1)
    }

    @Test("运行中的 Subagent 不报耗时")
    func runningSubagentHasNoDuration() {
        let spawn = use("sp", "Task", input: ["prompt": "go"], canonical: Canonical(kind: "agent.spawn", fields: ["subagentType": "explorer"]),
                        subagent: SubagentState(taskID: "task-1", status: "running", durationMs: 5_000))
        let rows = TranscriptRows.build(document([.toolUse(spawn)], running: true))
        guard case .subagent(let sub) = rows[2].content else { Issue.record("no subagent row"); return }
        #expect(sub.name == "explorer")
        #expect(sub.running)
        #expect(sub.durationMs == nil)
    }

    @Test("审批与提问各自成卡片行；一条助手消息只有一行署名")
    func cardsAndHeader() {
        let doc = document([
            .text("我要删掉 build"),
            .permission(PermissionRequest(requestID: "r1", toolCallID: "", toolName: "Bash")),
            .question(QuestionRequest(requestID: "q1", toolCallID: "", questions: ["继续吗？"])),
        ], running: true)
        #expect(names(TranscriptRows.build(doc)) == ["user", "agent", "text", "card", "card"])
    }

    @Test("步骤标签里的路径按会话的工作目录写成相对路径")
    func labelsUseTheConversationCwd() {
        let doc = document([.toolUse(readUse("a", path: "/repo/internal/chat.go"))], running: false)
        guard case .step(let step) = TranscriptRows.build(doc, cwd: "/repo")[2].content else { Issue.record("no step row"); return }
        #expect(step.label.summary == "./internal/chat.go")
    }

    @Test("用户刚发出、agent 的预览尾巴已到而还没有持久帧：尾巴单起一条助手消息")
    func previewAfterUserMessage() {
        var doc = TranscriptDocument()
        doc.messages = [TranscriptMessage(id: "u1", role: .user, text: "在吗")]
        doc.running = true
        doc.liveText = "在，"
        #expect(names(TranscriptRows.build(doc)) == ["user", "agent", "text"])
    }

    @Test("行 id 在向前补历史时不变：消息以开启它的那一帧定身份")
    func rowIDsAreStable() {
        let doc = document([.toolUse(readUse("a")), .toolUse(readUse("b"))], running: false)
        let ids = TranscriptRows.build(doc).map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("message:a1:activity:tool:a"))
    }
}
