import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import SwiftUI
import Testing

/// 新建对话各屏的视图层断言：屏上呈现的事实，与逐屏命中区（发现的目标数 = 本屏放的可点元素数）。
@MainActor
@Suite("新建对话各屏")
struct NewConversationScreenTests {
    let agents = [
        agent("coder", projects: ["fe"], targets: [ExecTarget(rank: 1, deviceName: "mini", availability: .available, current: true)]),
        agent("reviewer", projects: ["root"], targets: [ExecTarget(rank: 1, deviceName: "studio", availability: .offline)]),
        agent("writer", targets: [ExecTarget(rank: 1, availability: .unpaired)]),
    ]

    func entry(query: String = "") async -> (NewConversationView, NewConversationModel) {
        let store = FakeConversationStore([saved("1", agent: "coder", last: 100)])
        let model = NewConversationModel(workspace: FakeWorkspace(agents: agents), store: store)
        await model.load()
        model.query = query
        return (NewConversationView(model: model, onPick: { _ in }, onBrowseProjects: {}), model)
    }

    // MARK: 入口

    @Test("入口：搜索、从项目里挑、最近用过与全部 Agent；每行是解析出的机器或具体的不可用原因")
    func entryShowsFacts() async throws {
        let labels = await HostedScreen(await entry().0).labels().joined(separator: "\n")
        #expect(labels.contains(text("newconv.recent")))
        #expect(labels.contains(text("newconv.allAgents")))
        #expect(labels.contains(text("newconv.fromProject")))
        #expect(labels.contains(text("newconv.currentTarget %@", "mini")))
        #expect(labels.contains(text("newconv.unavailableOn %@ %@", "studio", text("newconv.offline"))))
        #expect(labels.contains(text("newconv.unpaired")))
    }

    @Test("入口命中区：搜索框 + 从项目里挑 + 最近 1 行 + 全部 3 行，全都补满且互不重叠")
    func entryHitTargets() async throws {
        let view = await entry().0
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 6, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("搜索时只列匹配的 Agent，最近用过与从项目里挑让位")
    func searching() async throws {
        let (view, _) = await entry(query: "view")
        let labels = await HostedScreen(view).labels().joined(separator: "\n")
        #expect(labels.contains("reviewer"))
        #expect(!labels.contains("writer"))
        #expect(!labels.contains(text("newconv.recent")))
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 2, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    // MARK: 项目

    @Test("项目列表：每个项目一行")
    func projectList() async throws {
        let (_, model) = await entry()
        let view = NewConversationProjectList(model: model, onPick: { _ in })
        let labels = await HostedScreen(view).labels().joined(separator: "\n")
        for project in projectTree { #expect(labels.contains(project.name)) }
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 4, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("项目下的 Agent：直接成员与继承自父项目分两组标注")
    func projectAgents() async throws {
        let (_, model) = await entry()
        let view = NewConversationProjectAgents(model: model, project: projectTree[1], onPick: { _ in })
        let labels = await HostedScreen(view).labels().joined(separator: "\n")
        let direct = try #require(labels.range(of: text("newconv.directMembers")))
        let inherited = try #require(labels.range(of: text("newconv.inheritedMembers")))
        let coder = try #require(labels.range(of: "coder"))
        let reviewer = try #require(labels.range(of: "reviewer"))
        #expect(direct.lowerBound < coder.lowerBound && coder.lowerBound < inherited.lowerBound && inherited.lowerBound < reviewer.lowerBound, "\(labels)")
        #expect(!labels.contains("writer"))
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 2, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    // MARK: 草稿

    func loadedDraft(recorder: FakeRecorder = FakeRecorder()) async -> DraftConversationModel {
        let model = draft(project: projectTree[1], recorder: recorder)
        await model.loadPlan()
        return model
    }

    @Test("草稿：输入区上方两枚 chip——机器与项目；中央不写解释")
    func draftChips() async throws {
        let model = await loadedDraft()
        let view = DraftConversationView(model: model, onStarted: { _ in })
        let labels = await HostedScreen(view).labels()
        #expect(labels.contains { $0.contains("mini") })
        #expect(labels.contains { $0.contains("frontend") })
        #expect(!labels.joined().contains("coder"))
        let report = await hitTargetReport(of: view)
        // 机器 chip、项目 chip、输入框、发送。
        #expect(report.targets.count == 4, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("发出第一条消息后 chip 行退场；落库失败时如实说已在机器上跑起来、没进列表，并给重试")
    func draftAfterSendNotListed() async throws {
        let recorder = FakeRecorder()
        await recorder.failNext(1)
        let model = await loadedDraft(recorder: recorder)
        model.text = "修构建"
        await model.send()
        let view = DraftConversationView(model: model, onStarted: { _ in })
        let labels = await HostedScreen(view).labels().joined(separator: "\n")
        #expect(labels.contains("修构建"))
        #expect(labels.contains(text("newconv.notListed %@", "mini")))
        #expect(labels.contains(text("newconv.retry")))
        #expect(!labels.contains("frontend"))
        let report = await hitTargetReport(of: view)
        // 只剩重试：chip 行与输入区都已退场。
        #expect(report.targets.count == 1, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("派发没成时说连不上哪台机器，chip 行还在")
    func draftDispatchFailed() async throws {
        let dispatcher = FakeDispatcher()
        await dispatcher.fail(with: .unreachable)
        let model = draft(dispatcher: dispatcher)
        await model.loadPlan()
        model.text = "hi"
        await model.send()
        let labels = await HostedScreen(DraftConversationView(model: model, onStarted: { _ in })).labels().joined(separator: "\n")
        #expect(labels.contains(text("newconv.connectFailed %@", "mini")))
        #expect(labels.contains(text("newconv.noProject")))
    }

    // MARK: 机器面板

    @Test("机器面板：逐档次序号、机器名、后端种类；不可用档写明宿主的三种原因；自动挑时没有交回入口")
    func machinePanelAuto() async throws {
        let model = await loadedDraft()
        let view = NewConversationMachinePanel(model: model)
        let labels = await HostedScreen(view).labels().joined(separator: "\n")
        #expect(labels.contains(text("newconv.pickTargetTitle")))
        for fact in ["1", "studio", "claudecode", "mini", "codex", "laptop", "box", "5"] { #expect(labels.contains(fact), "\(fact)") }
        #expect(labels.contains(text("newconv.offline")))
        #expect(labels.contains(text("newconv.unpaired")))
        #expect(labels.contains(text("newconv.projectPathMissing")))
        #expect(!labels.contains(text("newconv.useAutoTarget")))
        let report = await hitTargetReport(of: view)
        // 只有可用的两档可点；不可用的三档列出但压暗、不可点。
        #expect(report.targets.count == 2, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("手动指定后面板底部出现交回自动挑")
    func machinePanelManual() async throws {
        let model = await loadedDraft()
        await model.pick(tiers[4])
        let view = NewConversationMachinePanel(model: model)
        let labels = await HostedScreen(view).labels().joined(separator: "\n")
        #expect(labels.contains(text("newconv.useAutoTarget")))
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 3, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("项目面板：不指定项目 + 每个项目一行")
    func projectPanel() async throws {
        let model = await loadedDraft()
        let view = NewConversationProjectPanel(model: model)
        let labels = await HostedScreen(view).labels().joined(separator: "\n")
        #expect(labels.contains(text("newconv.noProject")))
        #expect(labels.contains("components"))
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 5, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    // MARK: 措辞

    @Test("面板标题与三种不可用原因取自宿主原话；不带「只影响这一次」这类预告")
    func hostWording() throws {
        #expect(try text("newconv.pickTargetTitle", language: "zh-Hans") == "在哪台机器上跑")
        #expect(try text("newconv.useAutoTarget", language: "zh-Hans") == "交回自动挑")
        #expect(try text("newconv.noProject", language: "zh-Hans") == "不指定项目")
        #expect(try text("newconv.projectPathMissing", language: "zh-Hans") == "这台机器上未配置远端路径")
        #expect(try text("newconv.offline", language: "zh-Hans") == "离线")
        #expect(try text("newconv.unpaired", language: "zh-Hans") == "未配对")
        #expect(try text("newconv.pickTargetScope", language: "zh-Hans") == "⟨missing⟩")
    }
}
