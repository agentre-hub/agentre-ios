@testable import Agentre
import AgentreDomain
import AgentreRelay
import AgentreStore
import AgentreUI
import Foundation
import Testing

/// 装配层的接缝：承载机、失败的重述、游标回退、输入区的两个来源与回合事件、登出。
/// 伪服务端与伪中继在进程内，本地库与钥匙串是真的。
@MainActor
@Suite(.serialized)
struct AssemblyTests {
    /// 一条他端（origin-desktop）发起、经 machine-a 保存的会话。
    private func savedElsewhere(_ harness: Harness, _ environment: AppEnvironment) async throws -> ConversationKey {
        let session = MachineSession(
            conversationID: "conv-1", peerFingerprint: "origin-desktop", title: "Elsewhere", cwd: "/repo",
            backendType: "claudecode", lifecycleState: "idle"
        )
        return try await environment.store.save(session, via: harness.machine.fingerprint)
    }

    @Test("会话键上是发起端、承载机另记：审批、发消息、补拉都走承载机的 machine: 通道，以 conversation_id 指明对话")
    func conversationsGoToTheirCarrier() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let environment = try harness.environment()
        let key = try await savedElsewhere(harness, environment)
        #expect(key.machineFingerprint == "origin-desktop")
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }

        try await services.approvals.submitToolPermission(ToolPermissionReply(
            conversation: key, peerFingerprint: "origin-desktop", requestID: "perm-1", disposition: .allowOnce
        ))
        try await services.composerRelay.run(key, peerFingerprint: "origin-desktop", text: "hi", compact: false, permissionMode: "")

        let approval = try #require(harness.relay.calls(WireMethod.runtimeSubmitToolPermission).first)
        #expect(approval.target == "machine:machine-a")
        #expect(approval.payload.string(1) == "conv-1")
        #expect(approval.payload.string(2) == "origin-desktop")
        let run = try #require(harness.relay.calls(WireMethod.runtimeRun).first)
        #expect(run.target == "machine:machine-a")
        #expect(run.payload.string(3) == "conv-1")
        #expect(run.payload.string(5) == "/repo")
        #expect(!harness.relay.calls.contains { $0.target == "machine:origin-desktop" })
    }

    @Test("中继的失败在装配处按 RelayFailure.fact 重述，不落成「认不出」")
    func relayFailuresAreRestated() {
        #expect(FailureFact(presenting: RelayFailure.machineUnreachable) == .noMachineAvailable(.offline))
        #expect(AppFailure.fact(for: RelayFailure.machineUnreachable) == .noMachineAvailable(.offline))
        #expect(AppFailure.fact(for: RelayCallError.channelClosed) == .noMachineAvailable(.offline))
        #expect(AppFailure.fact(for: RelayCallError.updateRequired) == .updateRequired)
        #expect(AppFailure.fact(for: RelayCallError.timedOut) == .timedOut)
        #expect(AppFailure.fact(for: URLError(.notConnectedToInternet)) == .offline)
        #expect(AppFailure.fact(for: CancellationError()) == nil)
    }

    @Test("机器最高帧号低于本机游标：跟随那一步丢掉旧编号的帧、从头重拉，读到的是机器此刻的这一条")
    func rewindReplacesStaleFrames() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.machine.add(
            FakeMachine.Session(conversationID: "conv-1", title: "Reused"),
            frames: [WireNotification.textDelta("conv-1", seq: 0, "new 1"), WireNotification.textDelta("conv-1", seq: 0, "new 2")]
        )
        let environment = try harness.environment()
        let session = MachineSession(conversationID: "conv-1", title: "Reused")
        let key = try await environment.store.save(session, via: "machine-a")
        // 本机手里是旧编号下的 5 帧（那条会话已被删、会话号被复用）。
        let stale = try (1...5).map { seq in
            PulledFrame(seq: Int64(seq), createtime: 1, payload: try WireFrames.text("conv-1", "old \(seq)"))
        }
        try await environment.store.record(stale, into: key)
        #expect(try await environment.store.latestSeq(key) == 5)

        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        _ = try await eventually("re-pulled frames") {
            try await environment.store.latestSeq(key) == 2 ? true : nil
        }
        let texts = try await environment.store.transcript(key).map { try WireFrames.textOf($0.payload) }
        #expect(texts == ["new 1", "new 2"])
        _ = services
    }

    @Test("保存到手机时同样回退：已在库里、游标越过机器高水位的那条被整段换成机器此刻的帧")
    func saveToPhoneRewinds() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.machine.add(
            FakeMachine.Session(conversationID: "conv-1", title: "Reused"),
            frames: [WireNotification.textDelta("conv-1", seq: 0, "new 1")]
        )
        let environment = try harness.environment()
        let session = MachineSession(conversationID: "conv-1", title: "Reused")
        let key = try await environment.store.save(session, via: "machine-a")
        try await environment.store.record(
            [PulledFrame(seq: 4, createtime: 1, payload: try WireFrames.text("conv-1", "old 4"))], into: key
        )
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let machine = Machine(id: 10, fingerprint: "machine-a", name: "mac", online: true)
        try await ConversationSaver(store: environment.store, transfer: services.transfer).save(session, on: machine)
        let texts = try await environment.store.transcript(key).map { try WireFrames.textOf($0.payload) }
        #expect(texts == ["new 1"])
    }

    @Test("跟随接上即按机器此刻的清单刷新摘要：断线期间结束的一轮（边界帧不带号、补拉不回来）不再永远停在运行中")
    func followRefreshesSummary() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.machine.add(
            FakeMachine.Session(conversationID: "conv-1", title: "Done now", lifecycleState: "idle", waitingForInput: false),
            frames: [WireNotification.textDelta("conv-1", seq: 0, "all green")]
        )
        let environment = try harness.environment()
        // 本机最后一次看见它时，它还在跑、等你批准。
        let key = try await environment.store.save(
            MachineSession(conversationID: "conv-1", title: "Old", lifecycleState: "running", waitingForInput: true), via: "machine-a"
        )
        _ = environment.startServices()
        defer { Task { await environment.tearDown() } }

        let row = try await eventually("summary refreshed") {
            let row = try await environment.store.conversation(key)
            return row?.lifecycleState == "idle" ? row : nil
        }
        #expect(!row.waitingForInput)
        #expect(row.title == "Done now")
        let list = try #require(harness.relay.calls(WireMethod.sessionList).first)
        #expect(list.target == "machine:machine-a")
    }

    @Test("机器详情里手机自己新建的对话（清单对调用方不回显发起端）：读作已保存，再保存也不多出一行；他端发起的照旧未保存")
    func phoneStartedConversationIsSavedInMachineDetail() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let phone = try harness.credentials.deviceFingerprint().value
        harness.machine.add(
            FakeMachine.Session(conversationID: "conv-new", peerFingerprint: phone, title: "New"),
            frames: [WireNotification.userMessage("conv-new", seq: 0, "hello")]
        )
        harness.machine.add(FakeMachine.Session(conversationID: "conv-desk", peerFingerprint: "origin-desktop", title: "Desk"), frames: [])
        let environment = try harness.environment()
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let request = DispatchRequest(
            conversationID: "conv-new", title: "New", userText: "hello", agentSyncID: "", projectSyncID: nil,
            target: DispatchChoice(deviceFingerprint: "machine-a", deviceName: "mac-studio", backendType: "claudecode", cwd: "/work")
        )
        let key = try await services.startedRecorder.record(StartedConversation(request: request))

        let detail = services.detailModel(for: Machine(id: 10, fingerprint: "machine-a", name: "mac-studio", online: true))
        await detail.load()
        let mine = try #require(detail.rows.first { $0.session.conversationID == "conv-new" })
        #expect(mine.key == key)
        #expect(mine.isSaved)
        #expect(detail.rows.first { $0.session.conversationID == "conv-desk" }?.isSaved == false)

        let machine = Machine(id: 10, fingerprint: "machine-a", name: "mac-studio", online: true)
        try await ConversationSaver(store: environment.store, transfer: services.transfer).save(mine.session, on: machine)
        #expect(try await environment.store.conversations().map(\.key) == [key])
        #expect(try await environment.store.conversation(key)?.peerFingerprint == phone)
    }

    @Test("服务端关掉承载机的通道：跟随停下并如实说出来，不留一条无声冻住的会话")
    func closedChannelIsReported() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.machine.add(FakeMachine.Session(conversationID: "conv-1", title: "Live"), frames: [])
        let environment = try harness.environment()
        let key = try await environment.store.save(MachineSession(conversationID: "conv-1", title: "Live"), via: "machine-a")
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        _ = try await eventually("followed") { harness.relay.calls(WireMethod.sessionAttach).isEmpty ? nil : true }
        try await Task.sleep(for: .milliseconds(200))
        #expect(services.failures.facts[key] == nil)

        harness.relay.closeChannels("machine:machine-a")
        let fact = try await eventually("failure reported") { services.failures.facts[key] }
        #expect(fact == .noMachineAvailable(.offline))
    }

    @Test("提及来源 = 工作区 Agent（按清单位置编号）+ 机器名册；面板的模型取服务端引擎目录的已启用模型，权限档位问承载机的 runtimeCapabilities")
    func composerSources() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let environment = try harness.environment()
        let key = try await savedElsewhere(harness, environment)
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }

        let mentions = try await services.mentions.mentionSources()
        #expect(mentions.agents == [ComposerMentionAgent(id: 1, name: "Builder")])
        #expect(mentions.devices == [ComposerMentionDevice(fingerprint: "machine-a", name: "mac-studio", online: true)])

        let conversation = try #require(try await environment.store.conversation(key))
        let settings = try await services.settings.settings(for: conversation)
        // 停用的不列；每个模型带上目录里人读的几格，下发仍用两枚键。
        #expect(settings.models == [ComposerModelChoice(providerKey: "anthropic", modelKey: "opus", modelId: "o", name: "Opus", providerName: "Anthropic")])
        #expect(settings.permissionModes == ["default", "plan"])
        #expect(settings.permissionMode == "default")
        let capabilities = try #require(harness.relay.calls(WireMethod.runtimeCapabilities).first)
        #expect(capabilities.target == "machine:machine-a")
        #expect(capabilities.payload.string(1) == "claudecode")
        #expect(harness.server.requests.contains { $0.url.path() == "/v1/engine/snapshot" })
    }

    @Test("两轮之间切档：只改本机当前档、不去问执行端也不报失败，下一轮 runtime.run 带上它")
    func permissionModeRidesTheNextRun() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let environment = try harness.environment()
        let key = try await savedElsewhere(harness, environment)
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let composer = try #require(await services.conversationModel(for: key)).composer
        await composer.load()
        #expect(composer.settings?.permissionMode == "default")

        await composer.setPermissionMode("plan")
        #expect(composer.failure == nil)
        #expect(composer.settings?.permissionMode == "plan")
        #expect(harness.relay.calls(WireMethod.runtimeSetPermissionMode).isEmpty)

        composer.edit(text: "go on", cursor: 5)
        await composer.send()
        let run = try #require(harness.relay.calls(WireMethod.runtimeRun).first)
        #expect(run.target == "machine:machine-a")
        #expect(run.payload.string(16) == "plan")
        #expect(composer.failure == nil)
    }

    @Test("一轮在跑时切档：额外调 runtime.setPermissionMode 即刻生效；执行端答没有进行中的一轮时如实报没改成、面板照旧")
    func permissionModeDuringATurn() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let environment = try harness.environment()
        let key = try await savedElsewhere(harness, environment)
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let screen = try #require(await services.conversationModel(for: key))
        let attached = Task { await screen.transcript.start() }
        defer { attached.cancel() }
        _ = try await eventually("transcript attached") {
            harness.relay.calls(WireMethod.sessionAttach).count >= 1 ? true : nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let composer = screen.composer
        await composer.load()

        // 手机开的这一轮：执行端登记着它，切档即刻生效。
        composer.edit(text: "go on", cursor: 5)
        await composer.send()
        harness.relay.notify("machine:machine-a", WireNotification.turnStarted("conv-1"))
        _ = try await eventually("turn running") { composer.isTurnRunning ? true : nil }
        await composer.setPermissionMode("plan")
        let applied = try #require(harness.relay.calls(WireMethod.runtimeSetPermissionMode).first)
        #expect(applied.target == "machine:machine-a")
        #expect(applied.payload.string(1) == "conv-1")
        #expect(applied.payload.string(3) == "plan")
        #expect(composer.failure == nil)
        #expect(composer.settings?.permissionMode == "plan")

        // 执行端已把这一轮收掉、收场帧还没到：那一次失败如实呈现，面板仍标注原档。
        harness.machine.finishTurn("conv-1")
        await composer.setPermissionMode("default")
        #expect(harness.relay.calls(WireMethod.runtimeSetPermissionMode).count == 2)
        #expect(composer.failure == .change)
        #expect(composer.settings?.permissionMode == "plan")
    }

    @Test("起手档位：转录里执行端最后报过的当前档；报过的档不在这台机器的可选范围里时退回执行端的默认档")
    func startingPermissionModeFromTheTranscript() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        // 帧只能来自机器：本机库里有而机器上没有的帧，跟随接上时会按机器的高水位整段回退。
        harness.machine.add(FakeMachine.Session(conversationID: "conv-1", peerFingerprint: "origin-desktop"), frames: [
            WireNotification.permissionModeChanged("conv-1", seq: 0, "default"),
            WireNotification.permissionModeChanged("conv-1", seq: 0, "plan"),
            WireNotification.textDelta("conv-1", seq: 0, "ok"),
        ])
        harness.machine.add(FakeMachine.Session(conversationID: "conv-2", peerFingerprint: "origin-desktop"), frames: [
            WireNotification.permissionModeChanged("conv-2", seq: 0, "bypassPermissions"),
        ])
        let environment = try harness.environment()
        let reported = try await savedElsewhere(harness, environment)
        let foreign = try await environment.store.save(
            MachineSession(conversationID: "conv-2", peerFingerprint: "origin-desktop", backendType: "claudecode", lifecycleState: "idle"),
            via: harness.machine.fingerprint
        )
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        _ = try await eventually("transcripts pulled from the machine") {
            let pulled = (try await environment.store.latestSeq(reported), try await environment.store.latestSeq(foreign))
            return pulled == (3, 1) ? true : nil
        }

        let conversation = try #require(try await environment.store.conversation(reported))
        #expect(try await services.settings.settings(for: conversation).permissionMode == "plan")
        let other = try #require(try await environment.store.conversation(foreign))
        #expect(try await services.settings.settings(for: other).permissionMode == "default")
    }

    @Test("输入区的回合事件由转录的实时帧喂入：开始 → 运行中，插话被取走即出队，结束 → 不再运行、无残留")
    func turnEventsFeedTheComposer() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.machine.add(FakeMachine.Session(conversationID: "conv-1", title: "Live"), frames: [])
        let environment = try harness.environment()
        let key = try await environment.store.save(MachineSession(conversationID: "conv-1", title: "Live"), via: "machine-a")
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let screen = try #require(await services.conversationModel(for: key))
        let attached = Task { await screen.transcript.start() }
        defer { attached.cancel() }
        _ = try await eventually("transcript attached") {
            harness.relay.calls(WireMethod.sessionAttach).count >= 1 ? true : nil
        }
        try await Task.sleep(for: .milliseconds(200))

        harness.machine.setLifecycle("conv-1", "running")
        harness.relay.notify("machine:machine-a", WireNotification.turnStarted("conv-1"))
        _ = try await eventually("turn running") { screen.composer.isTurnRunning ? true : nil }

        screen.composer.edit(text: "also check lint", cursor: 15)
        await screen.composer.send()
        let steer = try #require(harness.relay.calls(WireMethod.runtimeSteer).first)
        #expect(steer.target == "machine:machine-a")
        #expect(steer.payload.string(4) == "also check lint")
        let queued = try #require(screen.composer.queue.items.first)

        harness.relay.notify("machine:machine-a", WireNotification.steerConsumed("conv-1", queuedID: queued.id, text: "also check lint"))
        _ = try await eventually("steer consumed") { screen.composer.queue.items.isEmpty ? true : nil }

        harness.relay.notify("machine:machine-a", WireNotification.turnDone("conv-1"))
        _ = try await eventually("turn ended") { screen.composer.isTurnRunning ? nil : true }
        #expect(screen.composer.queue.dropped.isEmpty)
        // 同一条会话只有一份卡片状态与输入区。
        #expect(await services.conversationModel(for: key) === screen)
    }

    @Test("手机开的这一轮正常收场、插话整轮没被取走：收场后取回，接续成下一轮发出，不落成「未发送」")
    func leftoverSteerAfterOwnTurnContinues() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.machine.add(FakeMachine.Session(conversationID: "conv-1", title: "Live"), frames: [])
        let environment = try harness.environment()
        let key = try await environment.store.save(MachineSession(conversationID: "conv-1", title: "Live"), via: "machine-a")
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let screen = try #require(await services.conversationModel(for: key))
        let attached = Task { await screen.transcript.start() }
        defer { attached.cancel() }
        _ = try await eventually("transcript attached") {
            harness.relay.calls(WireMethod.sessionAttach).count >= 1 ? true : nil
        }
        try await Task.sleep(for: .milliseconds(200))

        screen.composer.edit(text: "write a long essay", cursor: 18)
        await screen.composer.send()
        harness.relay.notify("machine:machine-a", WireNotification.turnStarted("conv-1"))
        _ = try await eventually("turn running") { screen.composer.isTurnRunning ? true : nil }
        screen.composer.edit(text: "只回两个字：好的", cursor: 8)
        await screen.composer.send()
        #expect(screen.composer.queue.items.map(\.text) == ["只回两个字：好的"])

        // agentred 的收场次序：先把这一轮从会话表里摘掉，再发 run_result_done。
        harness.machine.finishTurn("conv-1")
        harness.relay.notify("machine:machine-a", WireNotification.turnDone("conv-1"))

        let runs = { harness.relay.calls(WireMethod.runtimeRun).map { $0.payload.string(11) } }
        _ = try await eventually("turn settled") {
            runs().count == 2 || !screen.composer.queue.dropped.isEmpty ? true : nil
        }
        #expect(screen.composer.queue.dropped.isEmpty)
        #expect(runs() == ["write a long essay", "只回两个字：好的"])
        #expect(screen.composer.queue.items.isEmpty)
    }

    @Test("执行端在一轮里报了新的档位（比如退出了计划模式）：用户这次没选过时，下一轮带的是它；用户选过的档不被报来的档顶掉")
    func reportedPermissionModeFollowsTheTranscript() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.machine.add(FakeMachine.Session(conversationID: "conv-1", peerFingerprint: "origin-desktop"), frames: [])
        let environment = try harness.environment()
        let key = try await savedElsewhere(harness, environment)
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let screen = try #require(await services.conversationModel(for: key))
        let attached = Task { await screen.transcript.start() }
        defer { attached.cancel() }
        _ = try await eventually("transcript attached") {
            harness.relay.calls(WireMethod.sessionAttach).count >= 1 ? true : nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let composer = screen.composer
        await composer.load()
        #expect(composer.settings?.permissionMode == "default")

        let reported = harness.machine.append("conv-1", [WireNotification.permissionModeChanged("conv-1", seq: 0, "plan")])
        harness.relay.notify("machine:machine-a", WireNotification.permissionModeChanged("conv-1", seq: reported[0], "plan"))
        _ = try await eventually("reported mode adopted") { composer.settings?.permissionMode == "plan" ? true : nil }
        composer.edit(text: "go on", cursor: 5)
        await composer.send()
        let run = try #require(harness.relay.calls(WireMethod.runtimeRun).first)
        #expect(run.payload.string(16) == "plan")

        harness.machine.finishTurn("conv-1")
        await composer.setPermissionMode("default")
        let again = harness.machine.append("conv-1", [WireNotification.permissionModeChanged("conv-1", seq: 0, "plan")])
        harness.relay.notify("machine:machine-a", WireNotification.permissionModeChanged("conv-1", seq: again[0], "plan"))
        _ = try await eventually("frame stored") { try await environment.store.latestSeq(key) >= again[0] ? true : nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(composer.settings?.permissionMode == "default")
    }

    @Test("会话信息里的「机器」是承载它的那台，不是会话键上的发起端")
    func sessionInfoShowsTheCarrier() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let environment = try harness.environment()
        let key = try await savedElsewhere(harness, environment)
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let screen = try #require(await services.conversationModel(for: key))
        let panel = Screen(ComposerPanel(model: screen.composer, contextUsage: nil, initialPage: .sessionInfo, onDeleted: {}))
        defer { panel.close() }
        let labels = try await panel.waitFor("conv-1")
        #expect(labels.contains("machine-a"), "\(labels)")
        #expect(!labels.contains("origin-desktop"), "\(labels)")
    }

    @Test("开着的对话屏上这条会话已不在本地库（承载机无从查起）：不拿会话键上的发起端去顶承载机")
    func missingCarrierIsNotTheOrigin() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let environment = try harness.environment()
        let key = try await savedElsewhere(harness, environment)
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let screen = try #require(await services.conversationModel(for: key))
        try await environment.store.delete(key)

        screen.composer.edit(text: "hi", cursor: 2)
        await screen.composer.send()
        await screen.cards.submit(.allowOnce, for: PermissionRequest(requestID: "perm-1", toolCallID: "", toolName: "Bash", input: nil))
        #expect(!harness.relay.calls.contains { $0.target == "machine:origin-desktop" })
    }

    @Test("跟随刷新摘要的应答在删掉这条会话之后才到：不把它收回本地库")
    func refreshAfterDeleteDoesNotResurrect() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.machine.add(FakeMachine.Session(conversationID: "conv-1", title: "Gone"), frames: [])
        let environment = try harness.environment()
        let store = environment.store
        let key = try await store.save(MachineSession(conversationID: "conv-1", title: "Gone"), via: "machine-a")
        harness.relay.beforeAnswering { method in
            if method == WireMethod.sessionList { try? await store.delete(key) }
        }
        _ = environment.startServices()
        defer { Task { await environment.tearDown() } }
        _ = try await eventually("summary asked") { harness.relay.calls(WireMethod.sessionList).isEmpty ? nil : true }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await store.conversation(key) == nil)
        #expect(try await store.conversations().isEmpty)
    }

    @Test("刷新被拒即登出：钥匙串与本地库一并清空，回到登录屏")
    func rejectedRefreshSignsOut() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn(accessToken: "expired")
        let environment = try harness.environment()
        let screen = Screen(AppRootView(environment: environment))
        defer { screen.close() }
        _ = try await environment.store.save(MachineSession(conversationID: "conv-1", title: "Kept"), via: "machine-a")
        try await screen.waitFor("Kept")

        // 服务端对带过期令牌的请求答 401，刷新也被拒。
        harness.server.rejectTokens()
        _ = try? await environment.transport.send(HTTPRequest(method: "GET", url: URL(string: "\(Harness.serverURL)/v1/devices")!))

        try await screen.waitFor(copy("login.signIn", table: "Login"))
        #expect(environment.session.phase == .signedOut)
        #expect(try harness.credentials.loadCredentials() == nil)
        #expect(try await environment.store.conversations().isEmpty)
        await environment.tearDown()
    }

    @Test("登出（这里是刷新被拒）先拆掉登录态那一套再清库：没有视图来拆也一样；「我」页不再留着上一个账号的资料与设备")
    func signOutStopsServicesAndForgetsTheAccount() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn(accessToken: "expired")
        let environment = try harness.environment()
        _ = environment.startServices()
        await environment.me.load()
        #expect(environment.me.profile != nil)

        harness.server.rejectTokens()
        _ = try? await environment.transport.send(HTTPRequest(method: "GET", url: URL(string: "\(Harness.serverURL)/v1/devices")!))

        #expect(environment.session.phase == .signedOut)
        #expect(environment.services == nil, "the signed-in services outlived the sign-out")
        #expect(environment.me.profile == nil && environment.me.devices.isEmpty && environment.me.failure == nil)
    }

    @Test("从登出状态起步（界面流程的启动环境）：上一次留在钥匙串里的令牌与库里的会话都不带进来，设备指纹不变")
    func startSignedOutDropsLeftovers() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let fingerprint = try harness.credentials.deviceFingerprint()
        do {
            let previous = try harness.environment()
            _ = try await savedElsewhere(harness, previous)
            #expect(try await !previous.store.conversations().isEmpty)
        }

        let environment = try AppEnvironment(harness.dependencies(), startSignedOut: true)

        #expect(environment.session.phase == .signedOut)
        #expect(try harness.credentials.loadCredentials() == nil)
        #expect(try await environment.store.conversations().isEmpty)
        #expect(try harness.credentials.deviceFingerprint() == fingerprint)
        #expect(AgentreApp.startsSignedOut(["AGENTRE_START_SIGNED_OUT": "1"]))
        #expect(!AgentreApp.startsSignedOut([:]))
    }

    @Test("作为测试宿主启动时不装配真实环境：不读真钥匙串里的令牌、不连默认的生产服务器、不开真实的本地库")
    func testHostBuildsNoLiveEnvironment() {
        #expect(AgentreApp.environment(for: ["XCTestConfigurationFilePath": "/tmp/run.xctestconfiguration"]) == nil)
    }

    /// 只交出预先排好的几帧的转录端口。
    private struct ScriptedTranscript: TranscriptRelay {
        let frames: [LiveTranscriptFrame]
        func pull(_ key: ConversationKey, peerFingerprint: String, cursor: Int64, limit: Int) async throws -> TranscriptPage {
            TranscriptPage(frames: [], cursor: cursor, hasMore: false, oldestSeq: 0)
        }
        func attach(_ key: ConversationKey, peerFingerprint: String, after: Int64) async throws -> AsyncStream<LiveTranscriptFrame> {
            AsyncStream { continuation in
                for frame in frames { continuation.yield(frame) }
            }
        }
    }

    @Test("回合事件递给输入区的那一步（轮末接续要几次往返）不压住实时帧：收场之后的帧照常到转录，回合事件仍按次序递")
    func turnFeedDoesNotHoldBackFrames() async throws {
        let text = LiveTranscriptFrame(seq: 7, createtime: nil, payload: try WireFrames.text("conv-1", "next turn"))
        let inner = ScriptedTranscript(frames: [
            LiveTranscriptFrame(seq: nil, createtime: nil, payload: WireNotification.turnDone("conv-1").data),
            LiveTranscriptFrame(seq: nil, createtime: nil, payload: WireNotification.turnStarted("conv-1").data),
            text,
        ])
        let gate = AsyncStream<Void>.makeStream()
        let fed = Fed()
        let relay = TurnFeedingTranscript(inner: inner) { signal in
            await fed.append(signal)
            if case .ended = signal { for await _ in gate.stream { break } }
        }
        let stream = try await relay.attach(ConversationKey(machineFingerprint: "m", conversationID: "conv-1"), peerFingerprint: "", after: 0)
        let received = Received()
        let reader = Task { for await frame in stream { await received.append(frame) } }
        defer { reader.cancel() }
        defer { gate.continuation.yield() }
        _ = try await eventually("the frame after the turn end, while the feed is still busy", seconds: 3) {
            await received.frames.contains(text) ? true : nil
        }
        #expect(await fed.signals == [.ended(normally: true)])
        gate.continuation.yield()
        _ = try await eventually("started fed after ended") { await fed.signals.count == 2 ? true : nil }
        #expect(await fed.signals == [.ended(normally: true), .started])
    }
}

private actor Received {
    private(set) var frames: [LiveTranscriptFrame] = []
    func append(_ frame: LiveTranscriptFrame) { frames.append(frame) }
}

private actor Fed {
    private(set) var signals: [TurnSignal] = []
    func append(_ signal: TurnSignal) { signals.append(signal) }
}
