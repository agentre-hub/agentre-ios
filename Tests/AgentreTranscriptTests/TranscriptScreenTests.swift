import AgentreDesign
import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import SwiftUI
import Testing

/// 转录屏的视图层断言：命中区（发现数 = 放置数，零即失败）与折叠态读得到的事实。
@MainActor
@Suite("转录屏")
struct TranscriptScreenTests {
    let decoder = FakeDecoder()

    static func format(_ key: String, _ args: any CVarArg...) -> String {
        let format = AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Conversation")
        return String(format: format, locale: Locale.current, arguments: args)
    }

    /// 一轮已落定的对话：一个 3 步的活动块、一个 Subagent、一步单独成行、一张待批准卡。
    func settledModel() async -> TranscriptModel {
        let spawn = use("sp", "Task", input: ["prompt": "go"], canonical: Canonical(kind: "agent.spawn", fields: ["taskDescription": "查日志"]))
        var events: [TranscriptEvent] = [
            .userMessage("修一下构建"), .turnStarted, .textDelta("先看看。"),
            .toolCall(readUse("r1")), .toolResult(result("r1", "a\nb")),
            .toolCall(use("c1", input: ["command": "pnpm test"])), .toolResult(result("c1", #"{"exitCode":1,"output":"boom"}"#)),
            .toolCall(readUse("r2")), .toolResult(result("r2")),
            .textDelta("派一个 Subagent。"),
            .toolCall(spawn),
            .subagent(SubagentUpdate(toolCallID: "sp", phase: .started, info: SubagentState(taskID: "task-1", status: "running"))),
        ]
        for i in 0..<3 {
            events.append(.toolCall(use("k\(i)", input: ["command": "ls"], parent: "sp")))
            events.append(.toolResult(ToolResult(toolCallID: "k\(i)", text: "ok", isError: false, parentID: "sp")))
        }
        events += [
            .subagent(SubagentUpdate(toolCallID: "sp", phase: .done, info: SubagentState(taskID: "task-1", status: "completed", durationMs: 12_300))),
            .toolResult(result("sp", "report")),
            .textDelta("再读一个文件。"),
            .toolCall(readUse("r3", path: "/repo/go.mod")), .toolResult(result("r3", "module x")),
            .permissionRequest(PermissionRequest(requestID: "p1", toolCallID: "", toolName: "Bash", input: ["command": "rm -rf build"])),
            .turnDone(TurnDone(durationMs: 6600)),
        ]
        let frames = events.enumerated().map { stored(decoder, Int64($0.offset + 1), $0.element) }
        let model = TranscriptModel(
            conversation: SavedConversation(key: conversationKey, lifecycleState: "idle"),
            store: FakeStore(frames), relay: FakeRelay(), decoder: decoder, pageSize: 10
        )
        await model.load()
        return model
    }

    @Test("每个可点元素都是补满 44×44 且互不重叠的按钮；检查器发现的数目等于放置的数目")
    func hitTargets() async throws {
        let model = await settledModel()
        // 上滚离开底部且其间来了新内容：回到最新的入口出现。
        model.userScrolledAway()
        await model.merge(live: [liveFrame(decoder, 1000, .userMessage("又一句"))])
        #expect(model.follow.unseen == 1)

        let placed = model.rows.count { row in
            switch row.content {
            case .activityHeader, .step, .elided, .subagent: true
            default: false
            }
        } + 1 // 回到最新
        #expect(placed == 4, "组头、Subagent、单独成行的一步、回到最新")

        let report = await hitTargetReport(of: TranscriptView(model: model, agentName: "Claude Code"))
        #expect(report.targets.count == placed, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("折叠态读得到：步数、固定顺序的汇总、红色失败数、耗时；Subagent 只一行：名称、步数、耗时，不带分类汇总")
    func collapsedFacts() async throws {
        let model = await settledModel()
        let labels = await HostedScreen(TranscriptView(model: model, agentName: "Claude Code")).labels().joined(separator: "\n")
        #expect(labels.contains("修一下构建"))
        #expect(labels.contains("Claude Code"))
        #expect(labels.contains(Self.format("activity.steps %lld", 3)))
        #expect(labels.contains(Self.format("activity.summary.read %lld", 2)))
        #expect(labels.contains(Self.format("activity.summary.command %lld", 1)))
        #expect(labels.contains(Self.format("activity.summary.failures %lld", 1)))
        #expect(labels.contains(Self.format("activity.duration %@", "6.6")))
        #expect(labels.contains(Self.format("subagent.title %@", "查日志")))
        #expect(labels.contains(Self.format("activity.duration %@", "12.3")))
        // Subagent 的内层汇总不出现在折叠行上（「命令 3」只在展开后的它自己的块里）。
        #expect(!labels.contains(Self.format("activity.summary.command %lld", 3)))
        // 单独成行的那一步：名字与相对路径就在转录里。
        #expect(labels.contains("/repo/go.mod"))
    }

    @Test("运行中的组头只留「执行中 · N 步」，不出耗时")
    func runningHeader() async throws {
        let frames = [
            stored(decoder, 1, .userMessage("跑一下")), stored(decoder, 2, .turnStarted),
            stored(decoder, 3, .toolCall(readUse("a"))), stored(decoder, 4, .toolResult(result("a"))),
            stored(decoder, 5, .toolCall(use("b", input: ["command": "make test"]))),
        ]
        let model = TranscriptModel(conversation: SavedConversation(key: conversationKey, lifecycleState: "running"), store: FakeStore(frames), relay: FakeRelay(), decoder: decoder)
        await model.load()
        let elements = await HostedScreen(TranscriptView(model: model, agentName: "Codex")).labels()
        let labels = elements.joined(separator: "\n")
        #expect(labels.contains(Self.format("activity.running %lld", 2)))
        // 运行态的组头不放分类汇总（耗时的留空由「转录行」的用例钉住）。
        let header = try #require(elements.first { $0.contains(Self.format("activity.running %lld", 2)) })
        #expect(!header.contains(Self.format("activity.summary.read %lld", 1)))
        #expect(labels.contains("make test"))
        #expect(labels.contains(Self.format("activity.row.running")))
    }

    @Test("上下文环：窗口不为正时整块不渲染；有值时是一枚补满命中区的按钮，读得到百分比")
    func contextRing() async throws {
        let none = await hitTargetReport(of: ContextRingView(usage: nil))
        #expect(none.targets.isEmpty)
        #expect(await HostedScreen(ContextRingView(usage: nil)).labels().isEmpty)

        let report = await hitTargetReport(of: ContextRingView(usage: ContextUsage(used: 45_000, max: 100_000)))
        #expect(report.targets.count == 1)
        #expect(report.violations.isEmpty, "\(report.violations)")
        let labels = await HostedScreen(ContextRingView(usage: ContextUsage(used: 45_000, max: 100_000))).labels().joined(separator: "\n")
        #expect(labels.contains("45%"))
    }

    @Test("上下文浮层只读：只给已用与上限的绝对值，没有任何可点元素")
    func contextDetailIsReadOnly() async throws {
        let detail = ContextUsageDetail(usage: ContextUsage(used: 45_000, max: 200_000))
        let report = await hitTargetReport(of: detail)
        #expect(report.targets.isEmpty)
        let labels = await HostedScreen(detail).labels().joined(separator: "\n")
        #expect(labels.contains(45_000.formatted()))
        #expect(labels.contains(200_000.formatted()))
    }

    @Test("三档变色：正常取 accent、告警取 waiting、危急取 failure")
    func ringTokens() {
        #expect(ContextRingView.token(for: .ok) == .accent)
        #expect(ContextRingView.token(for: .warn) == .waiting)
        #expect(ContextRingView.token(for: .danger) == .failure)
    }
}
