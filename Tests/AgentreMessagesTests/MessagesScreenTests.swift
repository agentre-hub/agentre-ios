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

    @Test("状态不只靠颜色：失败、运行中、等你处理的行各带一枚写明状态的图标，闲着的行不带")
    func statusIsNotColourOnly() async throws {
        let labels = await HostedScreen(await screen()).labels()
        let failed = try #require(labels.first { $0.contains("跑测试") }, "\(labels)")
        #expect(failed.contains(Self.text("messages.status.failed")), "\(failed)")
        let running = try #require(labels.first { $0.contains("修构建") }, "\(labels)")
        #expect(running.contains(Self.text("messages.status.running")), "\(running)")
        let waiting = try #require(labels.first { $0.contains("清理产物") }, "\(labels)")
        #expect(waiting.contains(Self.text("messages.status.waiting")), "\(waiting)")
        let idle = try #require(labels.first { $0.contains("整理文档") }, "\(labels)")
        for key in ["messages.status.failed", "messages.status.running", "messages.status.waiting"] {
            #expect(!idle.contains(Self.text(key)), "\(idle)")
        }
    }

    /// iPhone 17 的逻辑宽度，与列表行两侧各 16 的留白。
    static let phoneWidth: CGFloat = 402
    static let rowInset: CGFloat = 16

    @Test("标题从行首起排、占去行宽的大半：闲着的行与等你处理 / 运行中 / 失败的行都一样（iPhone 17 宽度）")
    func titleStartsAtRowLeadingAndFillsTheRow() async throws {
        let long = "只用文字回答，绝对不要调用任何工具、不要读写任何文件：写一段大约 800 字的短文，介绍 Go 语言的并发模型。"
        let rows = [
            SavedConversation(key: key("idle"), title: "闲着 · " + long, lifecycleState: "idle", lastMessageAt: 400, readMarker: 0, lastText: "好"),
            SavedConversation(
                key: key("waiting"), title: "等你 · " + long, lifecycleState: "running", waitingForInput: true, lastMessageAt: 300,
                pending: .permission(tool: "Bash", detail: "pwd")
            ),
            SavedConversation(key: key("typing"), title: "运行 · " + long, lifecycleState: "running", lastMessageAt: 200),
            SavedConversation(key: key("failed"), title: "失败 · " + long, lifecycleState: "failed", lastMessageAt: 100, readMarker: 100),
        ]
        // 整行在列表里是一个按钮，读屏把它合成一句；这里把同一个行视图按列表的行宽排开，量标题本身。
        let screen = HostedScreen(
            VStack(spacing: 8) { ForEach(rows) { MessageRow(conversation: $0) } }
                .padding(.horizontal, Self.rowInset)
                .frame(maxHeight: .infinity, alignment: .top),
            size: CGSize(width: Self.phoneWidth, height: 874)
        )
        let rowWidth = Self.phoneWidth - 2 * Self.rowInset
        for row in rows {
            let title = try #require(await screen.frame(of: row.title), "找不到标题 \(row.title)")
            // 行内留白加一枚状态图标的位置：标题不得再往右。
            #expect(title.minX - Self.rowInset <= 44, "\(row.key.conversationID)：标题起于 \(title.minX)")
            #expect(title.width >= rowWidth * 0.6, "\(row.key.conversationID)：标题宽 \(title.width) / 行宽 \(rowWidth)")
        }
    }
}
