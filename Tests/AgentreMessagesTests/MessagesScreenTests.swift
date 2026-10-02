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
                pending: .permission(tool: "Bash", detail: "rm -rf build"), pendingCount: 3
            ),
            SavedConversation(
                key: key("question"), title: "", lifecycleState: "running", waitingForInput: true, lastMessageAt: 200,
                pending: .question("用哪个分支？"), pendingCount: 1
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

    @Test("每一行与搜索框都是命中区补满 44×44 且互不重叠的可点区域：发现数 = 6")
    func hitTargets() async throws {
        let report = await hitTargetReport(of: await screen())
        #expect(report.targets.count == 6, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("不进对话即可读：待批准的命令与待回答的问题在行上，连同尚未处理的请求条数；运行中的行读作「正在输入…」；等你处理的行在最上面")
    func rowsCarryTheFacts() async throws {
        let labels = await HostedScreen(await screen()).labels().joined(separator: "\n")
        #expect(labels.contains("rm -rf build"))
        #expect(labels.contains("用哪个分支？"))
        #expect(labels.contains(Self.text("messages.typing")))
        // 运行中的行不再露出上一句话：它此刻就是在输入。
        #expect(!labels.contains("我先看一下日志"))
        #expect(labels.contains("文档整理好了"))
        // 没有标题的会话以会话 ID 认出。
        #expect(labels.contains("question"))
        // 行尾的琥珀计数：这条会话里尚未处理的请求条数。
        #expect(labels.contains("3"))
        let order = ["用哪个分支？", "rm -rf build", "修构建", "整理文档", "跑测试"].compactMap { labels.range(of: $0)?.lowerBound }
        #expect(order.count == 5)
        #expect(order == order.sorted(), "\(labels)")
    }

    @Test("等你处理的行副行是一句待处理事项：命令类写「请求执行 <命令>」，其余工具写「请求使用 <工具名>」，不另起一行列工具原名")
    func pendingLineIsOneSentence() async throws {
        let rows = [
            SavedConversation(
                key: key("command"), title: "清理产物", lifecycleState: "running", waitingForInput: true, lastMessageAt: 200,
                pending: .permission(tool: "Bash", detail: "rm -rf build"), pendingCount: 1
            ),
            SavedConversation(
                key: key("edit"), title: "改配置", lifecycleState: "running", waitingForInput: true, lastMessageAt: 100,
                pending: .permission(tool: "Edit", detail: "/repo/config.yaml"), pendingCount: 1
            ),
        ]
        let model = MessagesModel(store: FakeConversationStore(rows))
        await model.load()
        let labels = await HostedScreen(MessagesView(model: model, onOpen: { _ in })).labels()
        let joined = labels.joined(separator: "\n")
        #expect(joined.contains(String(format: Self.text("messages.pending.command %@"), "rm -rf build")), "\(labels)")
        #expect(joined.contains(String(format: Self.text("messages.pending.tool %@"), "Edit")), "\(labels)")
        // 工具原名不单独成行：它已经在那句话里（或由「请求执行」说清了种类）。
        #expect(!labels.contains("Bash") && !labels.contains("Edit"), "\(labels)")
    }

    @Test("头像右下角的状态点：等你处理琥珀、运行中绿，闲着与失败都不挂（规格「01 消息」：颜色只表这两档状态）")
    func avatarBadgeOnlyForWaitingAndRunning() async throws {
        let labels = await HostedScreen(await screen()).labels()
        let waiting = try #require(labels.first { $0.contains("清理产物") }, "\(labels)")
        #expect(waiting.contains(Self.text("messages.status.waiting")), "\(waiting)")
        let running = try #require(labels.first { $0.contains("修构建") }, "\(labels)")
        #expect(running.contains(Self.text("messages.status.running")), "\(running)")
        let idle = try #require(labels.first { $0.contains("整理文档") }, "\(labels)")
        let failed = try #require(labels.first { $0.contains("跑测试") }, "\(labels)")
        for label in [idle, failed] {
            for key in ["messages.status.failed", "messages.status.running", "messages.status.waiting"] {
                #expect(!label.contains(Self.text(key)), "\(label)")
            }
        }
    }

    /// iPhone 17 的逻辑宽度；行的左右留白与头像列宽由 `MessageRow` 自己给（规格「01 消息」）。
    static let phoneWidth: CGFloat = 402
    /// 头像（50）+ 头像与正文的间距（12）：标题不得排到这一列的左边。
    static let avatarColumn: CGFloat = 50 + 12

    @Test("标题从头像旁起排、占去所在列的大半：闲着的行与等你处理 / 运行中 / 失败的行都一样（iPhone 17 宽度）")
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
        // 行自己的左右留白（各 18）已经在 `MessageRow` 里，这里不再另加。
        let screen = HostedScreen(
            VStack(spacing: 8) { ForEach(rows) { MessageRow(conversation: $0, glyph: .neutral) } }
                .frame(maxHeight: .infinity, alignment: .top),
            size: CGSize(width: Self.phoneWidth, height: 874)
        )
        // 标题所在列的宽度：整行宽减左右留白（18×2）与头像列。
        let titleColumnWidth = Self.phoneWidth - 2 * 18 - Self.avatarColumn
        for row in rows {
            let title = try #require(await screen.frame(of: row.title), "找不到标题 \(row.title)")
            // 行左留白 + 头像列：标题不得再往右。
            #expect(title.minX <= 18 + Self.avatarColumn + 4, "\(row.key.conversationID)：标题起于 \(title.minX)")
            #expect(title.width >= titleColumnWidth * 0.5, "\(row.key.conversationID)：标题宽 \(title.width) / 列宽 \(titleColumnWidth)")
        }
    }
}
