@testable import Agentre
import AgentreDomain
import Foundation
import Testing

/// 三标签骨架里闭环之外的两条路：从消息列表新建对话（选 Agent → 草稿 → 发出第一句即入列并进入它），
/// 与「我」页退出登录（清钥匙串与本地库，回到登录屏）。
@MainActor
@Suite(.serialized)
struct ShellNavigationTests {
    @Test("消息 → 新建对话 → 选 Agent → 草稿落到机器 → 发出第一句：派到那台机器、落进本地库、进入这条对话")
    func newConversationFromMessages() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.server.route("GET /v1/workspace/dispatch-target", """
        {"agent_sync_id":"agent-1","tiers":[{"rank":1,"backend_sync_id":"b-1","device_name":"mac-studio","backend_type":"claudecode",\
        "kind":"agentred","availability":"available"}],"chosen":{"device_fingerprint":"machine-a","device_name":"mac-studio",\
        "backend_sync_id":"b-1","backend_type":"claudecode","kind":"agentred","cwd":"/repo"}}
        """)
        let environment = try harness.environment()
        let screen = Screen(AppRootView(environment: environment))
        defer { screen.close() }

        try await screen.tap(copy("newconv.title", table: "NewConversation"))
        try await screen.waitFor("Builder")
        try await screen.tap("Builder", exact: false)
        try await screen.waitFor("mac-studio")

        let services = try #require(environment.services)
        let draft = try #require(services.draftModel(for: .draft(agent: "agent-1", project: nil)))
        draft.text = "Tidy the README"
        try await screen.tap(copy("newconv.send", table: "NewConversation"))

        let run = try await eventually("dispatch") { harness.relay.calls(WireMethod.runtimeRun).first }
        #expect(run.target == "machine:machine-a")
        #expect(run.payload.string(11) == "Tidy the README")
        let conversationID = run.payload.string(3)
        // 发起端是本机（机器报的 peer_fingerprint 就是它），承载机是派到的那台。
        let phone = try harness.credentials.deviceFingerprint().value
        let key = ConversationKey(machineFingerprint: phone, conversationID: conversationID)
        #expect(try await environment.store.conversation(key)?.title == "Tidy the README")
        #expect(try await environment.store.carrier(of: key) == "machine-a")
        _ = try await eventually("conversation opened") {
            services.router.messages == [.conversation(key)] ? true : nil
        }
        try await screen.waitFor("Tidy the README")

        // 回到新建对话、再选同一个 Agent：进的是一张新草稿，而不是刚才那条已经开起来的对话。
        services.router.messages = [.newConversation, .draft(agent: "agent-1", project: nil)]
        let again = try #require(services.draftModel(for: .draft(agent: "agent-1", project: nil)))
        #expect(again !== draft)
        #expect(again.phase == .draft)
        #expect(again.sentText == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(services.router.messages.last == .draft(agent: "agent-1", project: nil))
        await environment.tearDown()
    }

    @Test("从机器标签进入一条已保存的对话也算读过；离开时把其间的新活动一并记成已读")
    func openingFromMachinesMarksRead() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let environment = try harness.environment()
        let key = try await environment.store.save(
            MachineSession(conversationID: "conv-1", title: "Seen", lastMessageAt: 5_000), via: "machine-a"
        )
        let screen = Screen(AppRootView(environment: environment))
        defer { screen.close() }
        try await screen.waitFor("Seen")
        let services = try #require(environment.services)

        try await screen.selectTab(1)
        services.router.machines = [.conversation(key)]
        _ = try await eventually("read on open") {
            try await environment.store.conversation(key)?.readMarker == 5_000 ? true : nil
        }
        _ = try await environment.store.save(
            MachineSession(conversationID: "conv-1", title: "Seen", lastMessageAt: 9_000), via: "machine-a"
        )
        services.router.machines = []
        _ = try await eventually("read on leave") {
            try await environment.store.conversation(key)?.readMarker == 9_000 ? true : nil
        }
        await environment.tearDown()
    }

    @Test("那台机器的协议版本与本 App 不等：机器详情说要更新 App，不说没连上；再刷新也不再对它握手")
    func machineDetailSaysUpdateRequired() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.relay.answerHandshakes(withVersion: "9.9.9")
        let environment = try harness.environment()
        let screen = Screen(AppRootView(environment: environment))
        defer { screen.close() }
        let services = try await eventually("signed in") { environment.services }
        try await screen.selectTab(1)
        try await screen.waitFor("mac-studio")
        let machine = try #require(services.machine("machine-a"))

        services.router.machines = [.machine("machine-a")]
        try await screen.waitFor(copy("failure.updateRequired", table: "Me"))
        let labels = await screen.labels()
        #expect(!labels.contains(copy("machines.detail.unreachable", table: "Machines")))

        await services.detailModel(for: machine).load()
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.relay.calls(WireMethod.authAccount).filter { $0.target == "machine:machine-a" }.count == 1)
        await environment.tearDown()
    }

    @Test("我 → 退出登录：账号信息在列；退出后回到登录屏，钥匙串与本地库都空了")
    func signOutFromMe() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let environment = try harness.environment()
        _ = try await environment.store.save(MachineSession(conversationID: "conv-1", title: "Previous account"), via: "machine-a")
        let screen = Screen(AppRootView(environment: environment))
        defer { screen.close() }
        try await screen.waitFor("Previous account")

        try await screen.selectTab(2)
        try await screen.waitFor("dev@example.test")
        // 退出登录在「我」页列表的最末一行，托管窗口里滚不到它：直接走它那枚按钮调用的同一个动作。
        await environment.me.signOut()

        try await screen.waitFor(copy("login.signIn", table: "Login"))
        #expect(try harness.credentials.loadCredentials() == nil)
        #expect(try await environment.store.conversations().isEmpty)
        _ = try await eventually("services torn down") { environment.services == nil ? true : nil }
    }
}
