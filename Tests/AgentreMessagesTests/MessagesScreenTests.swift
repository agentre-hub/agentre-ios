import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import SwiftUI
import Testing

/// 消息列表的视图层断言：逐屏命中区，以及不进对话即可读到的那些事实。
@MainActor
@Suite("消息列表屏")
struct MessagesScreenTests {
    static func text(_ key: String) -> String {
        AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Messages")
    }

    func sample() -> [SavedConversation] {
        [
            SavedConversation(key: key("idle"), title: "整理文档", lifecycleState: "idle", lastMessageAt: 400, readMarker: 400, lastText: "文档整理好了"),
            SavedConversation(key: key("typing"), title: "修构建", lifecycleState: "running", lastMessageAt: 500, lastText: "我先看一下日志"),
            SavedConversation(
                key: key("command"), title: "清理产物", lifecycleState: "running", waitingForInput: true, lastMessageAt: 100,
                pending: .permission(tool: "Bash", detail: "rm -rf build")
            ),
            SavedConversation(
                key: key("question"), title: "", lifecycleState: "running", waitingForInput: true, lastMessageAt: 200,
                pending: .question("用哪个分支？")
            ),
            SavedConversation(key: key("failed"), title: "跑测试", lifecycleState: "failed", lastMessageAt: 300, readMarker: 300),
        ]
    }

    func screen() async -> MessagesView {
        let model = MessagesModel(store: FakeConversationStore(sample()))
        await model.load()
        #expect(model.conversations.count == 5)
        return MessagesView(model: model, onOpen: { _ in })
    }

    @Test("每一行都是一个命中区补满 44×44 且互不重叠的按钮")
    func hitTargets() async throws {
        let report = await hitTargetReport(of: await screen())
        #expect(report.targets.count == 5, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("不进对话即可读：待批准的命令与待回答的问题在行上；运行中的行读作「正在输入…」；等你处理的行在最上面")
    func rowsCarryTheFacts() async throws {
        let labels = await HostedScreen(await screen()).labels().joined(separator: "\n")
        #expect(labels.contains("rm -rf build"))
        #expect(labels.contains("Bash"))
        #expect(labels.contains("用哪个分支？"))
        #expect(labels.contains(Self.text("messages.typing")))
        // 运行中的行不再露出上一句话：它此刻就是在输入。
        #expect(!labels.contains("我先看一下日志"))
        #expect(labels.contains("文档整理好了"))
        // 没有标题的会话以会话 ID 认出。
        #expect(labels.contains("question"))
        let order = ["用哪个分支？", "rm -rf build", "修构建", "整理文档", "跑测试"].compactMap { labels.range(of: $0)?.lowerBound }
        #expect(order.count == 5)
        #expect(order == order.sorted(), "\(labels)")
    }
}
