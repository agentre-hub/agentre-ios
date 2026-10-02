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
        #expect(labels.contains(String.localizedStringWithFormat(text("newconv.projectCount %lld"), 4)))
        #expect(labels.contains(text("newconv.currentTarget %@", "mini")))
        #expect(labels.contains(text("newconv.unavailableOn %@ %@", "studio", text("newconv.offline"))))
        #expect(labels.contains(text("newconv.unpaired")))
    }

    @Test("副行：落点是 `ink-3` 加服务器图标；不可用的原因用次级文字色（`ink-2`）加插头图标，不用红——不可用不是失败")
    func landingLineColours() {
        #expect(LandingLine(available: true) == LandingLine(icon: .server, token: .ink3))
        #expect(LandingLine(available: false) == LandingLine(icon: .plugZap, token: .ink2))
    }

    @Test("App 内选的语言与系统不同、再切回：搜索框与草稿输入框的占位与读屏标签随之换成那种语言")
    func fieldsFollowInAppLanguage() async throws {
        let entry = await inAppLanguageMismatches(of: await entry().0, bundle: AgentreUIResources.bundle, copy: [("newconv.search", "NewConversation")])
        #expect(entry.isEmpty, "\(entry)")
        let model = await loadedDraft()
        let draft = await inAppLanguageMismatches(
            of: DraftConversationView(model: model, onStarted: { _ in }), bundle: AgentreUIResources.bundle,
            copy: [("newconv.message", "NewConversation")]
        )
        #expect(draft.isEmpty, "\(draft)")
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

    // MARK: 从项目里挑

    func picker(selecting project: String) async -> (NewConversationProjectPicker, NewConversationModel) {
        let (_, model) = await entry()
        await model.selectProject(project)
        return (NewConversationProjectPicker(model: model, onPick: { _, _ in }), model)
    }

    @Test("从项目里挑：顶上是项目胶囊（子项目写「父 › 子」），下面直接成员，再按祖先由近到远各一组「继承自 <祖先>」")
    func projectPicker() async throws {
        let (view, _) = await picker(selecting: "deep")
        let labels = await HostedScreen(view).labels().joined(separator: "\n")
        for pill in ["agentre-server", "agentre-server › frontend", "agentre-server › frontend › components", "agentre"] {
            #expect(labels.contains(pill), "\(pill)")
        }
        let near = try #require(labels.range(of: text("newconv.inheritedFrom %@", "frontend")))
        let far = try #require(labels.range(of: text("newconv.inheritedFrom %@", "agentre-server")))
        let coder = try #require(labels.range(of: "coder"))
        let reviewer = try #require(labels.range(of: "reviewer"))
        #expect(near.lowerBound < coder.lowerBound && coder.lowerBound < far.lowerBound && far.lowerBound < reviewer.lowerBound, "\(labels)")
        #expect(!labels.contains(text("newconv.directMembers")))
        #expect(!labels.contains("writer"))
    }

    @Test("从项目里挑：每行写这个项目下的派发结果「当前落到 <机器> · <路径>」；跑不了写宿主原话的原因")
    func projectPickerLandings() async throws {
        let (_, model) = await picker(selecting: "fe")
        let view = NewConversationProjectPicker(model: model, onPick: { _, _ in })
        let labels = await HostedScreen(view).labels().joined(separator: "\n")
        #expect(labels.contains(text("newconv.directMembers")))
        #expect(labels.contains(text("newconv.landsOnPath %@ %@", "mini", "/srv/fe")), "\(labels)")
    }

    @Test("从项目里挑命中区：4 枚胶囊 + 2 行 Agent，全都补满且互不重叠")
    func projectPickerHitTargets() async throws {
        let (view, _) = await picker(selecting: "deep")
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 6, "\(report.targets)")
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
        // 机器 chip 上写等宽的后端种类。
        #expect(labels.contains { $0.contains("mini") && $0.contains("codex") }, "\(labels)")
        #expect(labels.contains { $0.contains("frontend") })
        let report = await hitTargetReport(of: view)
        // 返回、机器 chip、项目 chip、输入框、发送，工具行的 + / 权限模式 / 模型 / 思考档位。
        #expect(report.targets.count == 9, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("草稿：导航栏标题「新对话」、副标题是选中的 Agent")
    func draftNavigationBar() async throws {
        let model = await loadedDraft()
        let screen = HostedScreen(NavigationStack { DraftConversationView(model: model, onStarted: { _ in }) })
        let title = try #require(await screen.frame(of: text("newconv.title")))
        let subtitle = try #require(await screen.frame(of: "coder"))
        #expect(title.maxY <= subtitle.minY + 1, "\(title) \(subtitle)")
    }

    @Test("Pi 后端的草稿：工具行没有权限模式这一枚，面板里也没有这一行")
    func draftPiHasNoPermissionMode() async throws {
        let workspace = FakeWorkspace(planner: { query in
            DispatchPlan(agentSyncID: query.agentSyncID, tiers: [], chosen: DispatchChoice(
                deviceFingerprint: "fp-mini", deviceName: "mini", backendSyncID: "b-pi", backendType: "piagent", kind: "agentred"
            ))
        })
        let model = draft(workspace: workspace)
        await model.loadPlan()
        let permission = AgentreUIResources.bundle.localizedString(forKey: "composer.permissionMode", value: "⟨missing⟩", table: "Composer")
        let labels = await HostedScreen(DraftConversationView(model: model, onStarted: { _ in })).labels()
        #expect(labels.contains(AgentreUIResources.bundle.localizedString(forKey: "composer.model", value: "⟨missing⟩", table: "Composer")))
        #expect(!labels.contains(permission), "\(labels)")
        let panel = await HostedScreen(DraftToolPanel(model: model, initialPage: .root)).labels().joined(separator: "\n")
        #expect(!panel.contains(permission), "\(panel)")
    }

    @Test("工具面板：权限模式 / 模型 / 思考档位三行，没选时写「不指定」；选中的档在选项页打勾，选了就带进首条")
    func draftToolPanel() async throws {
        let model = await loadedDraft()
        let root = DraftToolPanel(model: model, initialPage: .root)
        let labels = await HostedScreen(root).labels().joined(separator: "\n")
        #expect(labels.contains(text("newconv.tool.unset")), "\(labels)")
        let report = await hitTargetReport(of: root)
        #expect(report.targets.count == 3, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
        model.chooseModel(sampleToolOptions.models[1])
        let page = DraftToolPanel(model: model, initialPage: .model)
        let options = await hitTargetReport(of: page)
        // 返回、不指定、两个模型。
        #expect(options.targets.count == 4, "\(options.targets)")
        #expect(options.violations.isEmpty, "\(options.violations)")
        #expect(await HostedScreen(DraftToolPanel(model: model, initialPage: .root)).labels().joined().contains("Opus"))
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
        // 只剩返回与重试：chip 行、输入区与工具行都已退场。
        #expect(report.targets.count == 2, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("完全离线：草稿里发不出去，如实说这台设备没有联网")
    func draftOffline() async throws {
        let model = await loadedDraft()
        model.text = "修构建"
        let online = HostedScreen(DraftConversationView(model: model, onStarted: { _ in }))
        #expect(await !online.disabledLabels().contains(text("newconv.send")))
        let screen = HostedScreen(DraftConversationView(model: model, onStarted: { _ in }).environment(\.isOffline, true))
        #expect(await screen.labels().contains(text("newconv.deviceOffline")))
        #expect(await screen.disabledLabels().contains(text("newconv.send")))
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

    @Test("那台机器的协议版本与本 App 不等：草稿里说要更新 App，而不是让人重试连接")
    func draftUpdateRequired() async throws {
        let dispatcher = FakeDispatcher()
        await dispatcher.fail(with: .updateRequired)
        let model = draft(dispatcher: dispatcher)
        await model.loadPlan()
        model.text = "hi"
        await model.send()
        let labels = await HostedScreen(DraftConversationView(model: model, onStarted: { _ in })).labels().joined(separator: "\n")
        let update = AgentreUIResources.bundle.localizedString(forKey: "failure.updateRequired", value: "⟨missing⟩", table: "Me")
        #expect(labels.contains(update), "\(labels)")
        #expect(!labels.contains(text("newconv.connectFailed %@", "mini")))
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
        #expect(try text("newconv.inheritedFrom %@", language: "zh-Hans") == "继承自 %@")
        #expect(try text("newconv.fromProject", language: "zh-Hans") == "从项目里挑")
        #expect(try text("newconv.message", language: "zh-Hans") == "说点什么，开始这次对话…")
        #expect(try text("newconv.title", language: "zh-Hans") == "新对话")
        #expect(try text("newconv.offline", language: "zh-Hans") == "离线")
        #expect(try text("newconv.unpaired", language: "zh-Hans") == "未配对")
        #expect(try text("newconv.pickTargetScope", language: "zh-Hans") == "⟨missing⟩")
    }
}
