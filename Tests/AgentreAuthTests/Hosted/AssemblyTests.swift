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
        try await services.composerRelay.run(key, peerFingerprint: "origin-desktop", text: "hi", compact: false)

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
        #expect(FailureFact(presenting: RelayFailure.machineUnreachable) == .unknown)
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
        try await environment.store.record(stale, into: key, via: "machine-a")
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
            [PulledFrame(seq: 4, createtime: 1, payload: try WireFrames.text("conv-1", "old 4"))], into: key, via: "machine-a"
        )
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let machine = Machine(id: 10, fingerprint: "machine-a", name: "mac", online: true)
        try await ConversationSaver(store: environment.store, transfer: services.transfer).save(session, on: machine)
        let texts = try await environment.store.transcript(key).map { try WireFrames.textOf($0.payload) }
        #expect(texts == ["new 1"])
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
        #expect(settings.models == [ComposerModelChoice(providerKey: "anthropic", modelKey: "opus")])
        #expect(settings.permissionModes == ["default", "plan"])
        #expect(settings.permissionMode == "default")
        let capabilities = try #require(harness.relay.calls(WireMethod.runtimeCapabilities).first)
        #expect(capabilities.target == "machine:machine-a")
        #expect(capabilities.payload.string(1) == "claudecode")
        #expect(harness.server.requests.contains { $0.url.path() == "/v1/engine/snapshot" })
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
}
