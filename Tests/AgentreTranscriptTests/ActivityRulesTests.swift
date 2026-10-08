import AgentreDomain
import Testing

/// 活动块汇总与聚合：逐条移植宿主 transcript-rows.test.ts 的「活动块聚合」与
/// activity-block/block.test.tsx 里由纯函数决定的那些判据（facts.ts 没有独立用例，
/// 其规则经 block.test.tsx 验）。
@Suite("活动块汇总")
struct ActivityRulesTests {
    func activity(_ items: [TranscriptItem], _ index: Int) throws -> ActivityGroup {
        guard case .activity(let group) = items[index] else {
            Issue.record("item \(index) is \(items[index]), not an activity block")
            throw CancellationError()
        }
        return group
    }

    func labels(_ group: ActivityGroup) -> [String] {
        group.steps.map { step in
            switch step {
            case .thinking(_, let text): "thinking:\(text)"
            case .tool(_, let use, _): "tool:\(use.name)"
            }
        }
    }

    func kinds(_ items: [TranscriptItem]) -> [String] {
        items.map { item in
            switch item {
            case .text: "text"
            case .thinking: "thinking"
            case .activity: "activity"
            case .subagent: "subagent"
            case .card(_, .permission): "permission"
            case .card(_, .question): "question"
            case .card(_, .tool(let use, _)): "card:\(use.canonical?.kind ?? "")"
            }
        }
    }

    @Test("连续的思考与工具折成一个活动块，步骤保持发生顺序")
    func foldsContiguousActivity() throws {
        let items = TranscriptItems.build(messageID: "m5", blocks: [
            .thinking("t1"), .toolUse(readUse("toolu-1")), .toolResult(result("toolu-1")), .toolUse(use("toolu-2")), .toolResult(result("toolu-2")),
        ])
        #expect(kinds(items) == ["activity"])
        let group = try activity(items, 0)
        #expect(labels(group) == ["thinking:t1", "tool:Read", "tool:Bash"])
        guard case .tool(_, let tool, let paired) = group.steps[1] else { Issue.record("not a tool step"); return }
        #expect(tool.id == "toolu-1")
        #expect(paired?.text == "ok")
        #expect(group.summary.steps == 3)
    }

    @Test("组头汇总按固定顺序输出，超过 4 类时截断并置 truncated；失败计数不参与截断")
    func fixedOrderAndTruncation() throws {
        let items = TranscriptItems.build(messageID: "m1", blocks: [
            .toolUse(use("toolu-cmd1")),
            .toolUse(use("toolu-other", "mcp__x__y", input: ["foo": "bar"])),
            .toolResult(result("toolu-other", "boom", isError: true)),
            .thinking("a"), .thinking("b"),
            .toolUse(readUse("toolu-read")),
            .toolUse(use("toolu-edit", "Edit", input: ["old_string": "x"], canonical: editCanonical([("a.ts", 3, 1), ("b.ts", 2, 2)]))),
            .toolUse(use("toolu-write", "Write", input: ["content": "x", "file_path": "/w.ts"])),
            .toolUse(use("toolu-cmd2")),
        ])
        let summary = try activity(items, 0).summary
        #expect(summary.parts == [
            ActivitySummaryPart(category: .thinking, count: 2),
            ActivitySummaryPart(category: .read, count: 1),
            ActivitySummaryPart(category: .edit, count: 1, files: 2, plus: 5, minus: 3),
            ActivitySummaryPart(category: .write, count: 1),
        ])
        #expect(summary.truncated)
        #expect(summary.steps == 8)
        #expect(summary.failures == 1)
    }

    @Test("失败与类目正交：失败的 Read 仍计一次查阅，且四类以内不截断")
    func failuresAreOrthogonal() throws {
        let items = TranscriptItems.build(messageID: "m1", blocks: [
            .toolUse(readUse("toolu-1")), .toolResult(result("toolu-1", "x", isError: true)),
            .toolUse(readUse("toolu-2")), .toolResult(result("toolu-2")),
            .toolUse(use("toolu-3")), .toolResult(result("toolu-3", "x", isError: true)),
        ])
        let summary = try activity(items, 0).summary
        #expect(summary.parts == [ActivitySummaryPart(category: .read, count: 2), ActivitySummaryPart(category: .command, count: 1)])
        #expect(!summary.truncated)
        #expect(summary.failures == 2)
    }

    @Test("本轮已失败终结时，没配到结果的一步也计进组头失败数；默认没结果 ≠ 失败")
    func unresolvedFailed() throws {
        let items = TranscriptItems.build(messageID: "m1", blocks: [
            .toolUse(readUse("toolu-1")), .toolResult(result("toolu-1")), .toolUse(use("toolu-2")), .toolUse(use("toolu-3")),
        ])
        let steps = try activity(items, 0).steps
        #expect(ActivityRules.summarize(steps).failures == 0)
        #expect(ActivityRules.summarize(steps, unresolvedFailed: true).failures == 2)
    }

    @Test("命令以非零退出码结束但结果没标 isError 时，仍计进组头失败数（status failed/error/interrupted 同理）")
    func exitCodeCountsAsFailure() throws {
        let items = TranscriptItems.build(messageID: "m1", blocks: [
            .toolUse(use("toolu-1")), .toolResult(result("toolu-1", #"{"exitCode":1,"output":"boom","status":"completed"}"#)),
            .toolUse(use("toolu-2")), .toolResult(result("toolu-2", #"{"exitCode":0,"output":"ok","status":"completed"}"#)),
            .toolUse(use("toolu-3")), .toolResult(result("toolu-3", #"{"output":"gone","status":"interrupted"}"#)),
        ])
        #expect(try activity(items, 0).summary.failures == 2)
    }

    @Test("还在后台跑的命令单独计数，已终结的与前台的都不算；后台不改类目也不算失败")
    func backgroundCount() throws {
        let items = TranscriptItems.build(messageID: "m1", blocks: [
            .toolUse(backgroundUse("toolu-bg1", status: "running")), .toolResult(result("toolu-bg1", "Command running in background with ID: bg1")),
            .toolUse(backgroundUse("toolu-bg2", status: "completed")), .toolResult(result("toolu-bg2", "Command running in background with ID: bg2")),
            .toolUse(use("toolu-fg")), .toolResult(result("toolu-fg")),
        ])
        let summary = try activity(items, 0).summary
        #expect(summary.backgroundRunning == 1)
        #expect(summary.parts == [ActivitySummaryPart(category: .command, count: 3)])
        #expect(summary.failures == 0)
    }

    @Test("后台命令连启动 ACK 都还没回时也算在跑")
    func backgroundWithoutAck() throws {
        let items = TranscriptItems.build(messageID: "m1", blocks: [.toolUse(backgroundUse("toolu-bg", status: nil))])
        #expect(try activity(items, 0).summary.backgroundRunning == 1)
    }

    @Test("汇总被截断时，后台计数与失败计数都还在")
    func countsSurviveTruncation() throws {
        let failed = use("f", input: ["command": "x"])
        let steps: [ActivityStep] = [
            thinkingStep("t", "a"),
            toolStep("r", readUse("r")),
            toolStep("w", use("w", input: ["content": "x"])),
            toolStep("o", use("o", input: ["foo": "bar"])),
            toolStep("b", backgroundUse("b", status: "running"), result("b", "ack")),
            toolStep("f", failed, result("f", "boom", isError: true)),
        ]
        let summary = ActivityRules.summarize(steps)
        #expect(summary.truncated)
        #expect(summary.parts.count == ActivityRules.summaryMaxParts)
        #expect(summary.backgroundRunning == 1)
        #expect(summary.failures == 1)
    }

    @Test("同一文件改两次算一个文件，增删行累加")
    func sameFileTwice() throws {
        let items = TranscriptItems.build(messageID: "m1", blocks: [
            .toolUse(use("toolu-1", "Edit", input: ["old_string": "a"], canonical: editCanonical([("same.ts", 2, 1)]))),
            .toolUse(use("toolu-2", "Edit", input: ["old_string": "b"], canonical: editCanonical([("same.ts", 4, 3)]))),
        ])
        #expect(try activity(items, 0).summary.parts == [ActivitySummaryPart(category: .edit, count: 2, files: 1, plus: 6, minus: 4)])
    }

    @Test("正文打断聚合，前后各自成块且不重排")
    func textBreaksGrouping() throws {
        let items = TranscriptItems.build(messageID: "m1", blocks: [
            .toolUse(readUse("toolu-1")), .toolUse(readUse("toolu-2")), .text("中间的结论"), .toolUse(use("toolu-3")), .toolUse(use("toolu-4")),
        ])
        #expect(kinds(items) == ["activity", "text", "activity"])
        #expect(labels(try activity(items, 0)) == ["tool:Read", "tool:Read"])
        #expect(labels(try activity(items, 2)) == ["tool:Bash", "tool:Bash"])
    }

    @Test("四类出组项（审批 / 提问 / 计划审批 / Subagent 派生）不进活动块，打断聚合并各自独立")
    func fourCardKindsStayOut() throws {
        let pending = PermissionRequest(requestID: "req-1", toolCallID: "", toolName: "Bash")
        let question = QuestionRequest(requestID: "q-1", toolCallID: "", questions: [AskQuestion(question: "用哪个分支？")])
        let plan = use("toolu-plan", "ExitPlanMode2", input: ["plan": "x"], canonical: Canonical(kind: "plan.approve_request", fields: ["requestId": "p1"]))
        let spawn = use("toolu-spawn", "Task", input: ["prompt": "go"], canonical: Canonical(kind: "agent.spawn", fields: ["taskDescription": "查日志"]))
        let items = TranscriptItems.build(messageID: "m1", blocks: [
            .toolUse(readUse("toolu-1")), .toolUse(readUse("toolu-2")),
            .toolUse(spawn),
            .toolUse(readUse("toolu-3")), .toolUse(readUse("toolu-4")),
            .permission(pending),
            .toolUse(readUse("toolu-5")), .toolUse(readUse("toolu-6")),
            .question(question),
            .toolUse(readUse("toolu-7")), .toolUse(readUse("toolu-8")),
            .toolUse(plan),
            .toolUse(readUse("toolu-9")),
        ])
        #expect(kinds(items) == [
            "activity", "subagent", "activity", "permission", "activity", "question", "activity", "card:plan.approve_request", "activity",
        ])
        // 出组项一步都不算进上层活动块的步数。
        let counted = items.compactMap { item -> Int? in
            if case .activity(let group) = item { return group.summary.steps }
            return nil
        }
        #expect(counted == [2, 2, 2, 2, 1])
    }

    @Test("Subagent 的内层步骤归进它自己，不摊平进上层步数（「5 步」不写成「23 步」）")
    func subagentChildrenDoNotFlatten() throws {
        let spawn = use("toolu-spawn", "Task", input: ["prompt": "go"], canonical: Canonical(kind: "agent.spawn", fields: ["taskDescription": "查日志"]))
        var blocks: [TranscriptBlock] = [.toolUse(readUse("a")), .toolUse(spawn)]
        for i in 0..<18 {
            blocks.append(.toolUse(use("child-\(i)", input: ["command": "ls"], parent: "toolu-spawn")))
            blocks.append(.toolResult(ToolResult(toolCallID: "child-\(i)", text: "ok", isError: false, parentID: "toolu-spawn")))
        }
        blocks.append(.toolResult(result("toolu-spawn", "report")))
        blocks += [.toolUse(readUse("b")), .toolUse(readUse("c")), .toolUse(readUse("d")), .toolUse(readUse("e"))]
        let items = TranscriptItems.build(messageID: "m1", blocks: blocks)
        #expect(kinds(items) == ["activity", "subagent", "activity"])
        guard case .subagent(let sub) = items[1] else { return }
        #expect(sub.steps.count == 18)
        #expect(sub.result?.text == "report")
        #expect(try activity(items, 0).summary.steps + (try activity(items, 2).summary.steps) == 5)
    }

    @Test("已批准的审批被后续同名工具调用按先来先配消费，不再单独成卡；拒绝的保留")
    func resolvedPermissionIsConsumed() {
        var allowed = PermissionRequest(requestID: "r1", toolCallID: "", toolName: "Bash")
        allowed.resolved = true
        allowed.allowed = true
        var denied = PermissionRequest(requestID: "r2", toolCallID: "", toolName: "Bash")
        denied.resolved = true
        let items = TranscriptItems.build(messageID: "m1", blocks: [.permission(allowed), .toolUse(use("t1")), .permission(denied)])
        #expect(kinds(items) == ["activity", "permission"])
    }

    @Test("AskUserQuestion / ExitPlanMode 的工具调用与其结果都不单独出现（由卡片承担）")
    func askAndExitPlanToolUsesAreSkipped() {
        let items = TranscriptItems.build(messageID: "m1", blocks: [
            .toolUse(use("ask", "AskUserQuestion", input: ["questions": []])), .toolResult(result("ask", "answer")),
            .toolUse(use("exit", "ExitPlanMode", input: ["plan": "p"])), .toolResult(result("exit")),
        ])
        #expect(items.isEmpty)
    }

    @Test("单条不成组：一段活动只有一步时也是活动项；步骤 key 与它单独成行时一致，块 key 取首步身份")
    func singleStepStillActivity() throws {
        let items = TranscriptItems.build(messageID: "m5", blocks: [
            .text("前言"), .toolUse(readUse("toolu-1")), .toolResult(result("toolu-1")), .text("中间"), .thinking("独立思考"), .text("结论"),
        ])
        #expect(kinds(items) == ["text", "activity", "text", "activity", "text"])
        let lone = try activity(items, 1)
        #expect(labels(lone) == ["tool:Read"])
        #expect(lone.steps[0].id == "message:m5:tool:tool:toolu-1")
        #expect(lone.key == "message:m5:activity:tool:toolu-1")
        #expect(labels(try activity(items, 3)) == ["thinking:独立思考"])
    }

    @Test("首步无身份（思考）时活动块 key 回退到可见下标")
    func keyFallsBackToIndex() throws {
        let items = TranscriptItems.build(messageID: "m5", blocks: [.text("前言"), .thinking("t"), .toolUse(readUse("toolu-1"))])
        #expect(try activity(items, 1).key == "message:m5:activity:1")
    }

    @Test("claudecode 的 Read（file_path 形状）计入「查阅」而不是「其它」")
    func filePathCountsAsRead() throws {
        let items = TranscriptItems.build(messageID: "m1", blocks: [
            .toolUse(use("toolu-1", "Read", input: ["file_path": "/repo/a.ts"])), .toolUse(use("toolu-2", "Read", input: ["file_path": "/repo/b.ts"])),
        ])
        #expect(try activity(items, 0).summary.parts == [ActivitySummaryPart(category: .read, count: 2)])
    }

    @Test("流式思考不进组（它是那一刻承载实时尾巴的表面），前一个活动块标 growing")
    func streamingThinkingStaysOut() throws {
        let items = TranscriptItems.build(messageID: "m1", blocks: [.toolUse(readUse("toolu-1")), .toolUse(readUse("toolu-2"))], liveThinking: "still thinking…")
        #expect(kinds(items) == ["activity", "thinking"])
        #expect(items[1] == .thinking(key: "message:m1:thinking:live", text: "still thinking…", streaming: true))
        #expect(try activity(items, 0).growing)
    }
}

/// 一步的事实：折叠态的组头计数与展开后的行标记用同一判据。
@Suite("活动行事实")
struct StepFactsTests {
    @Test("命令以非零退出码结束而没标 isError：组头计数与行标记都判失败，行尾写「失败」")
    func sameJudgementFoldedAndExpanded() {
        let step = toolStep("s", use("s", input: ["command": "pnpm exec tsc -b"]), result("s", #"{"exitCode":2,"output":"2 errors","status":"completed"}"#))
        #expect(ActivityRules.summarize([step]).failures == 1)
        let facts = step.facts()
        #expect(facts.failed)
        #expect(facts.result == .failed)
        #expect(facts.resultText == "2 errors")
    }

    @Test("结果标了 isError 的命令：失败，行尾写「失败」")
    func isErrorFailure() {
        let step = toolStep("s", use("s", input: ["command": "pnpm lint"]), result("s", #"{"exitCode":1,"output":"boom"}"#, isError: true))
        #expect(step.facts().failed)
        #expect(step.facts().result == .failed)
    }

    @Test("退出码为 0 不算失败；输出只是原文，行尾不写")
    func success() {
        let step = toolStep("s", use("s", input: ["command": "pnpm test"]), result("s", #"{"exitCode":0,"output":"13 passed"}"#))
        #expect(!step.facts().failed)
        #expect(step.facts().result == nil)
        #expect(step.facts().resultText == "13 passed")
    }

    @Test("没有结果的一步：默认报运行中；调用方声明本轮失败终结则按失败；已终结归属不明报结果未知")
    func pending() {
        let step = toolStep("s", use("s", input: ["command": "go build ./..."]))
        #expect(step.facts().pending == .running)
        #expect(!step.facts().failed)
        #expect(step.facts(pendingOutcome: .failed).failed)
        #expect(step.facts(pendingOutcome: .unknown).pending == .unknown)
    }

    @Test("仍在后台跑的命令报后台与任务 id；后台任务结束后不再报")
    func background() {
        let running = toolStep("s", backgroundUse("s", status: "running"), result("s", "ack"))
        #expect(running.facts().backgroundRunning)
        #expect(running.facts().backgroundTaskID == "bg-s")
        let done = toolStep("s", backgroundUse("s", status: "completed"), result("s", "ack"))
        #expect(!done.facts().backgroundRunning)
    }

    @Test("三档权重：读 / 中性 / 写；思考取最轻一档；MCP 名字拆成 server · tool")
    func weights() {
        #expect(toolStep("r", readUse("r")).weight == .read)
        let mcp = toolStep("m", use("m", "mcp__pencil__execute", input: ["commands": [["op": "set_node"]]]))
        #expect(mcp.weight == .neutral)
        #expect(mcp.label().name == "pencil · execute")
        #expect(toolStep("c", use("c", input: ["command": "pnpm test"])).weight == .write)
        #expect(thinkingStep("t", "hmm").weight == .read)
    }

    @Test("codex 的 file_change：行摘要是相对路径而不是整段 diff")
    func codexFileChangeLabel() {
        let diff = "@@ -1,2 +1,2 @@\n-" + String(repeating: "old ", count: 20_000)
        let step = toolStep("fc", use("fc", "file_change", input: ["changes": [["diff": .string(diff), "kind": "update", "path": "/repo/internal/app/chat.go"]]],
                                       canonical: editCanonical([("/repo/internal/app/chat.go", 1, 1)])))
        let label = step.label(cwd: "/repo")
        #expect(label.summary == "./internal/app/chat.go")
        #expect(step.facts().result == .changed(plus: 1, minus: 1))
    }

    @Test("超长单行结果：行尾不写原文，完整原文仍在结果正文里；读文件报行数")
    func longResultStaysInBody() {
        let huge = "head " + String(repeating: "x", count: 50_000) + " tail"
        let step = toolStep("h", use("h", input: ["command": "jq -c . big.json"]), result("h", huge))
        #expect(step.facts().result == nil)
        #expect(step.facts().resultText == huge)
        let multi = toolStep("m", readUse("m"), result("m", "a\nb\nc"))
        #expect(multi.facts().result == .lines(3))
    }

    @Test("shell 形态的步骤一律叫 Bash，摘要是命令本身")
    func shellLabel() {
        let label = toolStep("c", use("c", "command_execution", input: ["command": "/bin/zsh -lc 'go test ./...'"])).label()
        #expect(label.name == "Bash")
        #expect(label.summary == "go test ./...")
    }
}
