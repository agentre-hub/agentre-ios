@testable import Agentre
import AgentreDomain
import AgentreRelay
import Foundation
import Testing

/// 整条闭环，驱动的是装配好的 App 根视图：设备流登录 → 机器详情里把一条会话保存到手机 →
/// 消息列表见它等你处理、待批准的命令可读 → 打开读完转录 → 批准一次、发一句话 →
/// 全部拆掉、断网后从同一个库目录冷启动，历史照常可读。每一步断言的是用户看得见的东西。
@MainActor
@Suite(.serialized)
struct LoopTests {
    @Test("登录 → 保存 → 等你处理 → 读转录 → 批准并发一句 → 断网冷启动仍可读")
    func wholeLoop() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        // 机器上有一条桌面端（origin-desktop）发起的会话，停在一次 Bash 权限上。
        harness.machine.add(
            FakeMachine.Session(
                conversationID: "conv-42", peerFingerprint: "origin-desktop", title: "Fix flaky test",
                lifecycleState: "running", waitingForInput: true, lastMessageAt: 1_700_000_000_000
            ),
            frames: [
                WireNotification.userMessage("conv-42", seq: 0, "Please run the tests"),
                WireNotification.textDelta("conv-42", seq: 0, "Running the suite now."),
                WireNotification.permissionRequest(
                    "conv-42", seq: 0, requestID: "perm-1", tool: "Bash", input: #"{"command":"make test"}"#
                ),
            ]
        )

        var environment: AppEnvironment? = try harness.environment()
        var screen: Screen? = Screen(AppRootView(environment: environment!))

        // 1. 设备流登录：登录屏只有一个主操作；授权后直接进三标签骨架。
        try await screen!.tap(copy("login.signIn", table: "Login"))
        try await screen!.waitFor(copy("messages.title", table: "Messages"))
        #expect(harness.opener.opened == [URL(string: "https://server.test/device?code=ABCD-EFGH")!])
        #expect(try harness.credentials.loadCredentials()?.accessToken == "at-1")

        // 2. 机器 → 机器详情 → 保存到手机。
        try await screen!.selectTab(1)
        try await screen!.waitFor("mac-studio")
        try await screen!.tap("mac-studio", exact: false)
        try await screen!.waitFor("Fix flaky test")
        try await screen!.tap(copy("machines.detail.save", table: "Machines"))
        try await screen!.waitFor(copy("machines.detail.saved", table: "Machines"))

        // 3. 消息列表：这一条在列，等你处理，待批准的命令不进对话就读得到。二级页上没有 tab 栏，先退回机器名册。
        try await screen!.tap(copy("shell.back", table: "Shell"))
        try await screen!.selectTab(0)
        try await screen!.waitFor("Fix flaky test")
        try await screen!.waitFor("make test")

        // 4. 打开读转录。
        try await screen!.tap("Fix flaky test", exact: false)
        try await screen!.waitFor("Please run the tests")
        try await screen!.waitFor("Running the suite now.")

        // 5. 批准一次：经承载机 machine-a（不是发起端）发出，卡片落定为已允许。
        try await screen!.tap(copy("permission.allowOnce", table: "Cards"))
        let approval = try await eventually("approval sent") { harness.relay.calls(WireMethod.runtimeSubmitToolPermission).first }
        #expect(approval.target == "machine:machine-a")
        #expect(approval.payload.string(1) == "conv-42")
        #expect(approval.payload.string(2) == "origin-desktop")
        #expect(approval.payload.string(3) == "perm-1")
        #expect(approval.payload.bool(4))
        #expect(!approval.payload.bool(5))
        try await screen!.waitFor(copy("permission.allowed", table: "Cards"))
        // 机器落定这一问：实时帧（不带源端时刻）让摘要跟着走，列表上不再等你处理。
        harness.relay.notify("machine:machine-a", WireNotification.runtimeEvent(
            "conv-42", seq: 4, 20, Proto { r in
                r.string(1, "perm-1")
                r.bool(2, true)
            }
        ))

        // 6. 发一句话：一轮在跑，走插话；机器把它作为用户消息回显进转录。
        let key = ConversationKey(machineFingerprint: "origin-desktop", conversationID: "conv-42")
        // 对话屏已经建好的那一份（同一条会话只有一份，这里拿到的就是屏上那一份）。
        let conversation = try await eventually("conversation screen") { await environment!.services?.conversationModel(for: key) }
        conversation.composer.edit(text: "ship it", cursor: 7)
        try await screen!.tap(copy("composer.send", table: "Composer"))
        let sent = try await eventually("message sent") {
            harness.relay.calls.first { $0.method == WireMethod.runtimeSteer || $0.method == WireMethod.runtimeRun }
        }
        #expect(sent.target == "machine:machine-a")
        #expect(sent.payload.string(sent.method == WireMethod.runtimeSteer ? 1 : 3) == "conv-42")
        #expect(sent.payload.string(sent.method == WireMethod.runtimeSteer ? 4 : 11) == "ship it")
        harness.relay.notify("machine:machine-a", WireNotification.userMessage("conv-42", seq: 5, "ship it"))
        try await screen!.waitFor("ship it")
        _ = try await eventually("live frames stored") {
            try await environment!.store.latestSeq(key) == 5 ? true : nil
        }
        #expect(try await environment!.store.conversation(key)?.waitingForInput == false)

        // 7. 全部拆掉；断网；同一个库目录冷启动。
        await environment!.tearDown()
        screen!.close()
        screen = nil
        environment = nil
        harness.server.goOffline()
        harness.relay.goOffline()

        let reopened = try harness.environment()
        let offline = Screen(AppRootView(environment: reopened))
        defer { offline.close() }
        try await offline.waitFor("Fix flaky test")
        let labels = await offline.labels()
        #expect(!labels.contains { $0.contains("make test") })
        try await offline.tap("Fix flaky test", exact: false)
        try await offline.waitFor("Please run the tests")
        try await offline.waitFor("Running the suite now.")
        try await offline.waitFor(copy("permission.allowed", table: "Cards"))
        try await offline.waitFor("ship it")
        await reopened.tearDown()
    }
}
