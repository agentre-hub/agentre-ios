import AgentreDomain
@testable import AgentreUI
import Foundation
import Testing

/// 草稿对话：两枚 chip 定机器与项目，第一条消息派发并落进本地库。
@MainActor
@Suite("草稿对话视图模型")
struct DraftConversationModelTests {
    @Test("落到草稿即按次序自动挑，带上从项目里挑时选定的项目；chip 行在")
    func autoResolves() async throws {
        let workspace = FakeWorkspace()
        let model = draft(project: projectTree[1], workspace: workspace)
        await model.loadPlan()
        #expect(await workspace.planQueries == [DispatchPlanQuery(agentSyncID: "coder", projectSyncID: "fe")])
        #expect(model.machineChip == .machine("mini"))
        #expect(model.project?.syncID == "fe")
        #expect(model.manualTarget == nil)
        #expect(model.showsChips)
    }

    @Test("手动指定一档：按那一档重算；交回自动挑后又按次序解析")
    func manualOverride() async throws {
        let workspace = FakeWorkspace()
        let model = draft(workspace: workspace)
        await model.loadPlan()
        await model.pick(tiers[4])
        #expect(model.manualTarget == "b-box")
        #expect(model.machineChip == .machine("box"))
        await model.useAutomatic()
        #expect(model.manualTarget == nil)
        #expect(model.machineChip == .machine("mini"))
        #expect(await workspace.planQueries.map(\.targetBackendSyncID) == [nil, "b-box", nil])
    }

    @Test("不可用的档挑不了")
    func unavailableTierIsNotPickable() async throws {
        let workspace = FakeWorkspace()
        let model = draft(workspace: workspace)
        await model.loadPlan()
        await model.pick(tiers[0])
        #expect(model.manualTarget == nil)
        #expect(await workspace.planQueries.count == 1)
    }

    @Test("覆盖只对这一次生效：同一个 Agent 的下一条新对话仍按次序自动挑")
    func overrideIsOneShot() async throws {
        let workspace = FakeWorkspace()
        let first = draft(workspace: workspace)
        await first.loadPlan()
        await first.pick(tiers[4])
        first.text = "开工"
        await first.send()
        let second = draft(workspace: workspace)
        await second.loadPlan()
        #expect(second.manualTarget == nil)
        #expect(await workspace.planQueries.last == DispatchPlanQuery(agentSyncID: "coder"))
    }

    @Test("换项目重算；项目在机器上没配路径时说出这一具体原因，发不出去")
    func projectPathMissing() async throws {
        let workspace = FakeWorkspace(planner: { query in
            DispatchPlan(agentSyncID: query.agentSyncID, tiers: [
                DispatchTier(rank: 1, backendSyncID: "b1", deviceName: "mini", backendType: "codex", availability: query.projectSyncID == nil ? .available : .projectPathMissing),
            ], chosen: query.projectSyncID == nil ? choice("mini", backend: "b1") : nil)
        })
        let model = draft(workspace: workspace)
        await model.loadPlan()
        model.text = "hi"
        #expect(model.canSend)
        await model.choose(projectTree[3])
        #expect(model.project?.syncID == "other")
        #expect(model.machineChip == .unavailable(.projectPathMissing))
        #expect(!model.canSend)
        await model.choose(nil)
        #expect(model.project == nil)
        #expect(model.canSend)
        #expect(await workspace.planQueries.map(\.projectSyncID) == [nil, "other", nil])
    }

    @Test("手动指定的那一档跑不了时不回落，说出那一档的原因")
    func manualTierUnusable() async throws {
        let workspace = FakeWorkspace(planner: { query in
            DispatchPlan(agentSyncID: query.agentSyncID, tiers: [
                DispatchTier(rank: 1, backendSyncID: "b1", deviceName: "mini", availability: .available),
                DispatchTier(rank: 2, backendSyncID: "b2", deviceName: "box", availability: query.targetBackendSyncID == nil ? .available : .offline),
            ], chosen: query.targetBackendSyncID == nil ? choice("mini", backend: "b1") : nil)
        })
        let model = draft(workspace: workspace)
        await model.loadPlan()
        await model.pick(DispatchTier(rank: 2, backendSyncID: "b2", deviceName: "box", availability: .available))
        #expect(model.machineChip == .unavailable(.offline))
    }

    @Test("过时的计划应答不盖掉新的")
    func staleResponseIgnored() async throws {
        let workspace = FakeWorkspace()
        await workspace.configure(holdNextPlan: true)
        let model = draft(workspace: workspace)
        let first = Task { await model.loadPlan() }
        try await eventually("first plan in flight") { await workspace.isHoldingPlan }
        await model.pick(tiers[4])
        #expect(model.machineChip == .machine("box"))
        await workspace.releasePlan()
        await first.value
        #expect(model.machineChip == .machine("box"))
        #expect(model.manualTarget == "b-box")
    }

    @Test("换项目后计划重算期间发不出去：不会带着上一个项目的工作目录派发")
    func cannotSendWhileRecomputing() async throws {
        let workspace = FakeWorkspace()
        let dispatcher = FakeDispatcher()
        let model = draft(workspace: workspace, dispatcher: dispatcher)
        await model.loadPlan()
        model.text = "hi"
        #expect(model.canSend)
        await workspace.configure(holdNextPlan: true)
        let choosing = Task { await model.choose(projectTree[1]) }
        try await eventually("recompute in flight") { await workspace.isHoldingPlan }
        #expect(!model.canSend)
        #expect(model.machineChip == .resolving)
        await model.send()
        #expect(await dispatcher.requests.isEmpty)
        await workspace.releasePlan()
        await choosing.value
        #expect(model.canSend)
        await model.send()
        #expect(await dispatcher.requests.first?.target.cwd == "/srv/fe")
    }

    @Test("取计划失败如实记下")
    func planFailure() async throws {
        let workspace = FakeWorkspace()
        await workspace.configure(failPlans: true)
        let model = draft(workspace: workspace)
        await model.loadPlan()
        #expect(model.machineChip == .planFailed)
        #expect(!model.canSend)
    }

    @Test("第一条消息：以手机铸的号经选中那台机器派发，成功后立即落库；chip 行退场")
    func sendDispatchesThenRecords() async throws {
        let dispatcher = FakeDispatcher()
        let recorder = FakeRecorder()
        let model = draft(project: projectTree[1], dispatcher: dispatcher, recorder: recorder)
        await model.loadPlan()
        model.text = "  修一下构建\n日志在 ci 上 "
        await model.send()
        let request = try #require(await dispatcher.requests.first)
        #expect(request == DispatchRequest(
            conversationID: "0199aaaa-0000-7000-8000-000000000001", title: "修一下构建", userText: "修一下构建\n日志在 ci 上",
            agentSyncID: "coder", projectSyncID: "fe", target: choice("mini", backend: "b-mini", cwd: "/srv/fe")
        ))
        #expect(await recorder.recorded == [StartedConversation(request: request)])
        #expect(model.phase == .started(ConversationKey(machineFingerprint: "fp-mini", conversationID: "0199aaaa-0000-7000-8000-000000000001")))
        #expect(!model.showsChips)
        #expect(model.text.isEmpty)
    }

    @Test("派发没成：不落库，话留在输入框，chip 行还在，说连不上哪台机器")
    func dispatchFailure() async throws {
        let dispatcher = FakeDispatcher()
        await dispatcher.fail(with: .unreachable)
        let recorder = FakeRecorder()
        let model = draft(dispatcher: dispatcher, recorder: recorder)
        await model.loadPlan()
        model.text = "hi"
        await model.send()
        #expect(model.phase == .dispatchFailed(.unreachable, machine: "mini"))
        #expect(await recorder.recorded.isEmpty)
        #expect(model.text == "hi")
        #expect(model.showsChips)
        #expect(model.canSend)
    }

    @Test("派发成了而落库失败：如实是「已开始但未入列」，重试只重落库、不再派发一次")
    func recordFailureIsStartedButNotListed() async throws {
        let dispatcher = FakeDispatcher()
        let recorder = FakeRecorder()
        await recorder.failNext(2)
        let model = draft(dispatcher: dispatcher, recorder: recorder)
        await model.loadPlan()
        model.text = "hi"
        await model.send()
        guard case .notListed(let started) = model.phase else {
            Issue.record("expected notListed, got \(model.phase)")
            return
        }
        #expect(started.machineName == "mini")
        #expect(!model.showsChips)
        #expect(!model.canSend)

        await model.retryRecording()
        #expect(model.phase == .notListed(started))
        await model.retryRecording()
        #expect(model.phase == .started(ConversationKey(machineFingerprint: "fp-mini", conversationID: started.conversationID)))
        #expect(await dispatcher.requests.count == 1)
        #expect(await recorder.recorded == [started, started, started])
    }

    @Test("派发成功后这条对话必定在本地库里（真实数据库）")
    func recordsIntoRealStore() async throws {
        let directory = try TemporaryDirectory()
        let store = try LocalConversationStoreBox.open(directory)
        let model = draft(project: projectTree[0], recorder: StoreRecorder(store: store))
        await model.loadPlan()
        model.text = "整理文档"
        await model.send()
        let key = ConversationKey(machineFingerprint: "fp-mini", conversationID: "0199aaaa-0000-7000-8000-000000000001")
        #expect(model.phase == .started(key))
        let row = try #require(try await store.conversation(key))
        #expect(row.title == "整理文档")
        #expect(row.agentSyncID == "coder")
        #expect(row.projectSyncID == "root")
        #expect(row.cwd == "/srv/root")
        #expect(try await store.conversations().map(\.key) == [key])
    }

    // MARK: 工具行（权限模式 / 模型 / 思考档位）

    @Test("工具行的候选按机器 chip 选中的那台机器与后端问；草稿上选的三项随第一条 runtime.run 带过去")
    func toolChoicesRideTheFirstRun() async throws {
        let options = FakeToolOptions()
        let dispatcher = FakeDispatcher()
        let model = draft(dispatcher: dispatcher, options: options)
        await model.loadPlan()
        #expect(await options.queries == [choice("mini", backend: "b-mini")])
        #expect(model.toolOptions == sampleToolOptions)
        #expect(model.offersPermissionMode)
        model.choosePermissionMode("plan")
        model.chooseModel(sampleToolOptions.models[1])
        model.chooseReasoningEffort("high")
        #expect(model.permissionMode == "plan")
        #expect(model.modelChoice == sampleToolOptions.models[1])
        #expect(model.reasoningEffort == "high")
        model.text = "hi"
        await model.send()
        #expect(await dispatcher.requests.first?.settings == ComposerRunSettings(
            permissionMode: "plan", providerKey: "anthropic", modelKey: "opus", reasoningEffort: "high"
        ))
    }

    @Test("派发收尾钉住的才记进本地那一行：钉不住的那一项记作没选——机器的会话行上没有它，记下了下一次刷新就读成别的端改回了不指定")
    func onlyPinnedChoicesAreRecorded() async throws {
        let dispatcher = FakeDispatcher()
        await dispatcher.setPins(DispatchPins(modelTarget: false, reasoningEffort: true))
        let recorder = FakeRecorder()
        let model = draft(dispatcher: dispatcher, recorder: recorder, options: FakeToolOptions())
        await model.loadPlan()
        model.chooseModel(sampleToolOptions.models[1])
        model.chooseReasoningEffort("high")
        model.text = "hi"
        await model.send()
        let started = try #require(await recorder.recorded.first)
        #expect(started.providerKey.isEmpty)
        #expect(started.modelKey.isEmpty)
        #expect(started.reasoningEffort == "high")

        let pinned = FakeDispatcher()
        let pinnedRecorder = FakeRecorder()
        let both = draft(dispatcher: pinned, recorder: pinnedRecorder, options: FakeToolOptions())
        await both.loadPlan()
        both.chooseModel(sampleToolOptions.models[1])
        both.text = "hi"
        await both.send()
        let recorded = try #require(await pinnedRecorder.recorded.first)
        #expect(recorded.providerKey == "anthropic")
        #expect(recorded.modelKey == "opus")
    }

    @Test("一项都不选：三格留空，按 Agent 与后端的既有配置跑")
    func noToolChoicesLeaveFieldsEmpty() async throws {
        let dispatcher = FakeDispatcher()
        let model = draft(dispatcher: dispatcher, options: FakeToolOptions())
        await model.loadPlan()
        model.text = "hi"
        await model.send()
        #expect(await dispatcher.requests.first?.settings == ComposerRunSettings())
    }

    @Test("选回「不指定」即清掉那一项；候选以外的取值选不上")
    func unsetAndOutOfRange() async throws {
        let dispatcher = FakeDispatcher()
        let model = draft(dispatcher: dispatcher, options: FakeToolOptions())
        await model.loadPlan()
        model.choosePermissionMode("plan")
        model.choosePermissionMode(nil)
        model.choosePermissionMode("yolo")
        model.chooseModel(ComposerModelChoice(providerKey: "other", modelKey: "gpt"))
        model.chooseReasoningEffort("ultra")
        #expect(model.permissionMode == nil)
        #expect(model.modelChoice == nil)
        #expect(model.reasoningEffort == nil)
        model.text = "hi"
        await model.send()
        #expect(await dispatcher.requests.first?.settings == ComposerRunSettings())
    }

    @Test("改选机器后三项回到不指定、候选按新的那台重问；换项目而机器没变时不清")
    func machineChangeClearsChoices() async throws {
        let options = FakeToolOptions()
        let dispatcher = FakeDispatcher()
        let model = draft(dispatcher: dispatcher, options: options)
        await model.loadPlan()
        model.choosePermissionMode("plan")
        model.chooseModel(sampleToolOptions.models[0])
        model.chooseReasoningEffort("low")
        await model.choose(projectTree[1])
        #expect(model.permissionMode == "plan")
        #expect(model.reasoningEffort == "low")
        await model.pick(tiers[4])
        #expect(model.permissionMode == nil)
        #expect(model.modelChoice == nil)
        #expect(model.reasoningEffort == nil)
        #expect(await options.queries.last == choice("box", backend: "b-box", cwd: "/srv/fe"))
        model.text = "hi"
        await model.send()
        #expect(await dispatcher.requests.first?.settings == ComposerRunSettings())
    }

    @Test("换了机器之后才到的上一台的候选不落：工具行只列此刻选中那一台的")
    func staleToolOptionsAreDropped() async throws {
        let options = FakeToolOptions()
        let boxOptions = DraftToolOptions(permissionModes: ["default"], models: [])
        await options.set(boxOptions, for: "box")
        await options.holdNextQuery()
        let model = draft(options: options)
        let first = Task { await model.loadPlan() }
        try await eventually("mini's options in flight") { await options.isHolding }
        await model.pick(tiers[4])
        #expect(model.toolOptions == boxOptions)
        await options.release()
        await first.value
        #expect(model.toolOptions == boxOptions, "mini 的候选晚到，盖掉了 box 的")
    }

    @Test("Pi 后端不提供权限模式这一项：选不上，派发也不带")
    func piOffersNoPermissionMode() async throws {
        let workspace = FakeWorkspace(planner: { query in
            DispatchPlan(agentSyncID: query.agentSyncID, tiers: [
                DispatchTier(rank: 1, backendSyncID: "b-pi", deviceName: "mini", backendType: "piagent", kind: "agentred", availability: .available),
            ], chosen: DispatchChoice(deviceFingerprint: "fp-mini", deviceName: "mini", backendSyncID: "b-pi", backendType: "piagent", kind: "agentred"))
        })
        let dispatcher = FakeDispatcher()
        let model = draft(workspace: workspace, dispatcher: dispatcher, options: FakeToolOptions())
        await model.loadPlan()
        #expect(!model.offersPermissionMode)
        model.choosePermissionMode("plan")
        model.chooseReasoningEffort("medium")
        #expect(model.permissionMode == nil)
        model.text = "hi"
        await model.send()
        #expect(await dispatcher.requests.first?.settings == ComposerRunSettings(reasoningEffort: "medium"))
    }
}
