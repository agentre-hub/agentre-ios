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
        let key = ConversationKey(machineFingerprint: "machine-a", conversationID: conversationID)
        #expect(try await environment.store.conversation(key)?.title == "Tidy the README")
        #expect(try await environment.store.carrier(of: key) == "machine-a")
        _ = try await eventually("conversation opened") {
            services.router.messages == [.conversation(key)] ? true : nil
        }
        try await screen.waitFor("Tidy the README")
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
