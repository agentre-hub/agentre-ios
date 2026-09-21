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
        harness.relay.closeChannels("machine:machine-a")
        // 后台期间：通道被判死（跟随记下了事实），机器跑完了那一轮。
        _ = try await eventually("channel closed") { services.failures.facts[key] }
        harness.machine.append("conv-1", [WireNotification.userMessage("conv-1", seq: 0, "m3")])
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
}
