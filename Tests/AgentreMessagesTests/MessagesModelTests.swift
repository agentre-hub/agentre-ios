import AgentreDomain
@testable import AgentreUI
import Foundation
import Testing

/// 消息列表的视图模型：读本地库（注入伪仓储），按库的变动就地刷新，已读乐观改写。
@MainActor
@Suite("消息列表视图模型")
struct MessagesModelTests {
    func row(_ id: String, last: Int64, read: Int64? = nil, waiting: Bool = false, lifecycle: String = "idle") -> SavedConversation {
        SavedConversation(key: key(id), title: id, lifecycleState: lifecycle, waitingForInput: waiting, lastMessageAt: last, readMarker: read)
    }

    @Test("载入即按置顶与最后活动排好，角标两个数由库里的行现算")
    func loadsOrderedWithBadge() async throws {
        let store = FakeConversationStore([row("a", last: 300, read: 300), row("b", last: 100, waiting: true), row("c", last: 500)])
        let model = MessagesModel(store: store)
        await model.load()
        #expect(model.conversations.map(\.key.conversationID) == ["b", "c", "a"])
        #expect(model.badge == MessagesBadge(waiting: 1, unread: 2))
    }

    @Test("库一变，列表就地跟上：新的等待置顶、未读与角标随之变化")
    func followsStoreChanges() async throws {
        let store = FakeConversationStore([row("a", last: 300, read: 300), row("b", last: 100, read: 100)])
        let model = MessagesModel(store: store)
        await model.load()
        let following = Task { await model.follow() }
        defer { following.cancel() }
        #expect(model.badge == MessagesBadge(waiting: 0, unread: 0))
        try await eventually("model subscribed") { await store.observerCount == 1 }

        await store.set([row("a", last: 300, read: 300), row("b", last: 400, read: 100, waiting: true)])
        try await eventually("list follows the store") { model.conversations.first?.key.conversationID == "b" }
        #expect(model.badge == MessagesBadge(waiting: 1, unread: 1))
    }

    @Test("标记已读是乐观的：库还没答复时这一行已经是已读，角标同步减一")
    func markReadIsOptimistic() async throws {
        let store = FakeConversationStore([row("a", last: 300), row("b", last: 200)])
        await store.configure(holdReads: true)
        let model = MessagesModel(store: store)
        await model.load()
        #expect(model.badge.unread == 2)

        let marking = Task { await model.markRead(key("a")) }
        try await eventually("store asked") { await store.isHoldingRead }
        #expect(model.conversations.first { $0.key == key("a") }?.isUnread == false)
        #expect(model.badge.unread == 1)
        // 库在答复之前刷新一次，也不能把乐观改写冲回去。
        await model.load()
        #expect(model.conversations.first { $0.key == key("a") }?.isUnread == false)

        await store.releaseRead()
        await marking.value
        #expect(model.conversations.first { $0.key == key("a") }?.isUnread == false)
        #expect(await store.readRequests == [key("a")])
    }

    @Test("库没能记下已读时退回库里的真值")
    func failedMarkReadReverts() async throws {
        let store = FakeConversationStore([row("a", last: 300)])
        await store.configure(failReads: true)
        let model = MessagesModel(store: store)
        await model.load()
        await model.markRead(key("a"))
        #expect(model.conversations.first?.isUnread == true)
        #expect(model.badge.unread == 1)
    }

    @Test("冷启动、没有任何中继：真实本地库里已保存的会话直接出现在列表上")
    func coldStartShowsLocalContent() async throws {
        let directory = try TemporaryDirectory()
        do {
            let store = try openStore(directory)
            try await store.save(summary("conv-1", title: "修构建", lastMessageAt: 1_000), via: machine)
            try await store.record([live(userMessage("conv-1", "帮我修一下构建"), seq: 1)], via: machine)
        }
        let model = MessagesModel(store: try openStore(directory))
        await model.load()
        let first = try #require(model.conversations.first)
        #expect(first.title == "修构建")
        #expect(first.lastText == "帮我修一下构建")
        #expect(first.isUnread)
    }
}
