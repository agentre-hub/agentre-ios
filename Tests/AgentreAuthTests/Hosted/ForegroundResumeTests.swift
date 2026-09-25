@testable import Agentre
import AgentreDomain
import AgentreStore
import AgentreUI
import Foundation
import Testing

/// 挂起回前台（规格「失败与恢复」前两行）：连接断开、或服务端关掉了承载机的通道之后，回到前台
/// （`SignedInServices.resume`，即 scenePhase 变回 .active 与网络恢复时根视图做的那一步），
/// 打开着的对话屏续上——其间机器上多出的帧与刚发出的用户消息都在屏上，不丢不重。
@MainActor
@Suite(.serialized)
struct ForegroundResumeTests {
    private func userTexts(_ screen: ConversationScreenModel) -> [String] {
        screen.transcript.document.messages.filter { $0.role == .user }.map(\.text)
    }

    /// 一条保存在本机、历史已同步进库的会话，对话屏已打开并接上实时帧；刚发出的一句（m2）实时到达屏上。
    private func openConversation(_ harness: Harness) async throws -> (AppEnvironment, SignedInServices, ConversationScreenModel, Task<Void, Never>) {
        harness.machine.add(
            FakeMachine.Session(conversationID: "conv-1", title: "Live"),
            frames: [WireNotification.userMessage("conv-1", seq: 0, "m1")]
        )
        let environment = try harness.environment()
        let key = try await environment.store.save(MachineSession(conversationID: "conv-1", title: "Live"), via: "machine-a")
        let services = environment.startServices()
        _ = try await eventually("synced") { try await environment.store.latestSeq(key) == 1 ? true : nil }
        let screen = try #require(await services.conversationModel(for: key))
        let open = Task { await screen.transcript.start() }
        _ = try await eventually("transcript attached") {
            harness.relay.calls(WireMethod.sessionAttach).count >= 2 ? true : nil
        }
        try await Task.sleep(for: .milliseconds(200))

        let sent = harness.machine.append("conv-1", [WireNotification.userMessage("conv-1", seq: 0, "m2")])
        harness.relay.notify("machine:machine-a", WireNotification.turnStarted("conv-1"))
        harness.relay.notify("machine:machine-a", WireNotification.userMessage("conv-1", seq: sent[0], "m2"))
        _ = try await eventually("sent message on screen") { userTexts(screen) == ["m1", "m2"] ? true : nil }
        return (environment, services, screen, open)
    }

    @Test("连接断开期间机器跑完一轮：回到前台后对话屏从转录自己的最新帧号续上，刚发的那句仍在，不重复")
    func connectionLossResumes() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let (environment, services, screen, open) = try await openConversation(harness)
        defer {
            open.cancel()
            Task { await environment.tearDown() }
        }

        harness.relay.dropConnections()
        harness.machine.append("conv-1", [WireNotification.userMessage("conv-1", seq: 0, "m3")])
        await services.resume()

        _ = try await eventually("caught up") { userTexts(screen).last == "m3" ? true : nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(userTexts(screen) == ["m1", "m2", "m3"])
    }

    @Test("服务端关掉了承载机的通道（后台期间判死）：回到前台重新 attach，从转录自己的最新帧号补，刚发的那句仍在，不重复")
    func closedChannelResumes() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let (environment, services, screen, open) = try await openConversation(harness)
        defer {
            open.cancel()
            Task { await environment.tearDown() }
        }
        let attachesBefore = harness.relay.calls(WireMethod.sessionAttach).count

        let key = screen.conversation.key
        let pullsBefore = harness.relay.calls(WireMethod.sessionPull).count
        // 后台期间：通道被判死，机器跑完了那一轮。
        try await suspend(.channelClosed, harness, services, key) {
            harness.machine.append("conv-1", [WireNotification.userMessage("conv-1", seq: 0, "m3")])
        }
        await services.resume()

        _ = try await eventually("caught up") { userTexts(screen).last == "m3" ? true : nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(userTexts(screen) == ["m1", "m2", "m3"])
        #expect(services.failures.facts[key] == nil)
        // 跟随与转录各自重新 attach；补拉都从已有的最新帧号（m2 = 2）接着来，不从头下载。
        #expect(harness.relay.calls(WireMethod.sessionAttach).count >= attachesBefore + 2)
        let pullsAfter = harness.relay.calls(WireMethod.sessionPull).dropFirst(pullsBefore)
        #expect(!pullsAfter.isEmpty)
        #expect(pullsAfter.allSatisfy { $0.payload.int(3) >= 2 })
    }

    // MARK: 后台期间这一轮收场

    /// 进后台的两种断法：连接断了（通道随重连自己重新 attach），或服务端判死了承载机的通道（回前台重新 attach）。
    enum Suspension: String, CaseIterable, CustomTestStringConvertible {
        case connectionDropped, channelClosed
        var testDescription: String { rawValue }
    }

    /// 进后台：先断开，紧接着让机器在 App 看不见的这段时间里发生的事（`whileAway`）落到伪机器上，
    /// 再等 App 处理完这次断开。
    ///
    /// `whileAway` 与断开在同一段主执行器上的同步代码里完成：App 要重新接上（跟随报出事实、回前台）
    /// 都得先回到主执行器，所以此后任何一次 attach / 补拉看到的都已是机器的这份新状态。若先等 App
    /// 反应再改机器，App 可能已经自己接回了通道——那之后机器上多出的帧真机会实时推过来，伪机器不推，
    /// 用例就在与 App 的恢复抢跑。
    ///
    /// 通道被关时等的条件只会由假变真：跟随报出了事实，或已经重新 attach（事实随之清掉）。
    /// 单等事实会漏掉「报出与接回同在一毫秒内」的那一次。
    private func suspend(
        _ suspension: Suspension, _ harness: Harness, _ services: SignedInServices, _ key: ConversationKey,
        whileAway: () -> Void = {}
    ) async throws {
        switch suspension {
        case .connectionDropped:
            harness.relay.dropConnections()
            whileAway()
        case .channelClosed:
            let attaches = harness.relay.calls(WireMethod.sessionAttach).count
            harness.relay.closeChannels("machine:machine-a")
            whileAway()
            _ = try await eventually("channel closed") {
                services.failures.facts[key] != nil || harness.relay.calls(WireMethod.sessionAttach).count > attaches ? true : nil
            }
        }
    }

    private func runTexts(_ harness: Harness) -> [String] {
        harness.relay.calls(WireMethod.runtimeRun).map { $0.payload.string(11) }
    }

    @Test("这一轮在后台期间收场（收场帧没推过来）：回前台后停止钮消失，下一句直接开新一轮", arguments: Suspension.allCases)
    func turnEndedInBackground(_ suspension: Suspension) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let (environment, services, screen, open) = try await openConversation(harness)
        defer {
            open.cancel()
            Task { await environment.tearDown() }
        }
        harness.machine.setLifecycle("conv-1", "running")
        _ = try await eventually("turn running") { screen.composer.canStop ? true : nil }

        try await suspend(suspension, harness, services, screen.conversation.key) {
            harness.machine.append("conv-1", [WireNotification.textDelta("conv-1", seq: 0, "done")])
            harness.machine.setLifecycle("conv-1", "idle")
            harness.machine.finishTurn("conv-1")
        }
        await services.resume()

        _ = try await eventually("stop button gone") { screen.composer.canStop ? nil : true }
        #expect(!screen.composer.isTurnRunning)
        screen.composer.edit(text: "next", cursor: 4)
        // 轮末那一问（信箱里还剩什么）在路上时发送不可用；问完即可直接发。
        _ = try await eventually("can send") { screen.composer.canSend ? true : nil }
        await screen.composer.send()
        #expect(runTexts(harness) == ["next"], "the next message opened a new turn instead of queueing as a steer")
        #expect(harness.relay.calls(WireMethod.runtimeSteer).isEmpty)
    }

    @Test("后台期间收场的那一轮信箱里还剩一条插话：回前台后取回一次、接续一次；再回前台不再取、不再发", arguments: Suspension.allCases)
    func leftoverSteerContinuesOnce(_ suspension: Suspension) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let (environment, services, screen, open) = try await openConversation(harness)
        defer {
            open.cancel()
            Task { await environment.tearDown() }
        }
        harness.machine.setLifecycle("conv-1", "running")
        _ = try await eventually("turn running") { screen.composer.canStop ? true : nil }
        screen.composer.edit(text: "also lint", cursor: 9)
        await screen.composer.send()
        #expect(screen.composer.queue.items.map(\.text) == ["also lint"])

        try await suspend(suspension, harness, services, screen.conversation.key) {
            harness.machine.setLifecycle("conv-1", "idle")
            harness.machine.finishTurn("conv-1")
        }
        await services.resume()

        _ = try await eventually("leftover steer continued") { runTexts(harness) == ["also lint"] ? true : nil }
        #expect(screen.composer.queue.items.isEmpty)
        #expect(screen.composer.queue.dropped.isEmpty)
        // 再进一次后台、再回前台：那一轮早就处置过了，不再问信箱、不再开一轮。
        let drains = harness.relay.calls(WireMethod.runtimeDrainPending).count
        #expect(drains == 1)
        try await suspend(suspension, harness, services, screen.conversation.key)
        await services.resume()
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.relay.calls(WireMethod.runtimeDrainPending).count == drains)
        #expect(runTexts(harness) == ["also lint"])
    }

    @Test("回前台时这一轮还在跑：停止钮仍在，不问信箱", arguments: Suspension.allCases)
    func turnStillRunningAfterForeground(_ suspension: Suspension) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let (environment, services, screen, open) = try await openConversation(harness)
        defer {
            open.cancel()
            Task { await environment.tearDown() }
        }
        harness.machine.setLifecycle("conv-1", "running")
        _ = try await eventually("turn running") { screen.composer.canStop ? true : nil }
        let attaches = harness.relay.calls(WireMethod.sessionAttach).count

        try await suspend(suspension, harness, services, screen.conversation.key) {
            harness.machine.append("conv-1", [WireNotification.textDelta("conv-1", seq: 0, "still going")])
        }
        await services.resume()

        _ = try await eventually("re-attached") { harness.relay.calls(WireMethod.sessionAttach).count > attaches ? true : nil }
        try await Task.sleep(for: .milliseconds(500))
        #expect(screen.composer.canStop)
        #expect(harness.relay.calls(WireMethod.runtimeDrainPending).isEmpty)
    }

    // MARK: 发出后应答没到就进了后台

    /// 打开着的对话屏，上一轮（m2）已正常收场：此刻发出的一句开新一轮。
    private func idleConversation(_ harness: Harness) async throws -> (AppEnvironment, SignedInServices, ConversationScreenModel, Task<Void, Never>) {
        let opened = try await openConversation(harness)
        let screen = opened.2
        harness.relay.notify("machine:machine-a", WireNotification.turnDone("conv-1"))
        screen.composer.edit(text: "probe", cursor: 5)
        _ = try await eventually("previous turn settled") { !screen.composer.isTurnRunning && screen.composer.canSend ? true : nil }
        screen.composer.edit(text: "", cursor: 0)
        return opened
    }

    /// 回前台时机器上那一轮的状态。
    enum TurnAtReturn: String, CaseIterable, CustomTestStringConvertible {
        case ended, running
        var testDescription: String { rawValue }
    }

    @Test(
        "发出后应答没到就进后台、机器已受理并开跑：回前台后不说没发出、不把原文放回输入框，停止钮按机器此刻的状态",
        arguments: Suspension.allCases, TurnAtReturn.allCases
    )
    func acceptedSendWhoseAnswerWasLost(_ suspension: Suspension, _ atReturn: TurnAtReturn) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let (environment, services, screen, open) = try await idleConversation(harness)
        defer {
            open.cancel()
            Task { await environment.tearDown() }
        }
        // report-7 11f：agentred 已开跑，手机那一路此后什么都没到——没有应答，也没有开轮帧（点发送 2 秒后仍无 Stop）。
        harness.relay.lose(next: WireMethod.runtimeRun, .answer)
        screen.composer.edit(text: "write kotlin", cursor: 12)
        let sending = Task { await screen.composer.send() }
        _ = try await eventually("machine took the turn") { runTexts(harness) == ["write kotlin"] ? true : nil }
        #expect(!screen.composer.canStop)

        try await suspend(suspension, harness, services, screen.conversation.key) {
            guard atReturn == .ended else { return }
            harness.machine.append("conv-1", [WireNotification.textDelta("conv-1", seq: 0, "fun main() {}")])
            harness.machine.setLifecycle("conv-1", "idle")
            harness.machine.finishTurn("conv-1")
        }
        await services.resume()
        await sending.value

        #expect(screen.composer.failure == nil, "reported as not sent although the machine ran it")
        #expect(screen.composer.text.isEmpty, "the sent text was put back into the input")
        _ = try await eventually("sent message on screen") { userTexts(screen).last == "write kotlin" ? true : nil }
        switch atReturn {
        case .ended:
            try await Task.sleep(for: .milliseconds(300))
            #expect(!screen.composer.canStop)
        case .running:
            _ = try await eventually("stop button for the turn still running") { screen.composer.canStop ? true : nil }
        }
        #expect(runTexts(harness) == ["write kotlin"], "sent twice")
    }

    @Test("发出的请求没到机器连接就断了：回前台后如实说没发出，原文回到输入框", arguments: Suspension.allCases)
    func unacceptedSendIsReportedNotSent(_ suspension: Suspension) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let (environment, services, screen, open) = try await idleConversation(harness)
        defer {
            open.cancel()
            Task { await environment.tearDown() }
        }
        harness.relay.lose(next: WireMethod.runtimeRun, .request)
        screen.composer.edit(text: "write kotlin", cursor: 12)
        let sending = Task { await screen.composer.send() }
        try await Task.sleep(for: .milliseconds(300))

        try await suspend(suspension, harness, services, screen.conversation.key)
        await services.resume()
        await sending.value

        #expect(screen.composer.failure == .send)
        #expect(screen.composer.text == "write kotlin")
        #expect(!screen.composer.canStop)
        #expect(runTexts(harness).isEmpty)
    }

    @Test("手机新建的对话（发起端 = 本机）这一轮在后台期间收场：回前台后停止钮消失，本地库仍只有这一行", arguments: Suspension.allCases)
    func phoneStartedTurnEndedInBackground(_ suspension: Suspension) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let phone = try harness.credentials.deviceFingerprint().value
        harness.machine.add(
            FakeMachine.Session(conversationID: "conv-new", peerFingerprint: phone, title: "New", lifecycleState: "running"),
            frames: [WireNotification.userMessage("conv-new", seq: 0, "hello")]
        )
        let environment = try harness.environment()
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        let request = DispatchRequest(
            conversationID: "conv-new", title: "New", userText: "hello", agentSyncID: "", projectSyncID: nil,
            target: DispatchChoice(deviceFingerprint: "machine-a", deviceName: "mac-studio", backendType: "claudecode", cwd: "/work")
        )
        let key = try await services.startedRecorder.record(StartedConversation(request: request))
        _ = try await eventually("synced") { try await environment.store.latestSeq(key) == 1 ? true : nil }
        let screen = try #require(await services.conversationModel(for: key))
        let open = Task { await screen.transcript.start() }
        defer { open.cancel() }
        #expect(screen.composer.canStop)

        try await suspend(suspension, harness, services, key) {
            harness.machine.setLifecycle("conv-new", "idle")
            harness.machine.finishTurn("conv-new")
        }
        await services.resume()

        _ = try await eventually("stop button gone") { screen.composer.canStop ? nil : true }
        #expect(try await environment.store.conversations().map(\.key) == [key])
        #expect(try await environment.store.conversation(key)?.lifecycleState == "idle")
    }
}
