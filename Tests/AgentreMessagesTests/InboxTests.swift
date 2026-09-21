import AgentreDomain
import Testing

/// 领域层状态：消息列表的排序与置顶、未读判定、角标（规格 Testing decisions「领域层状态」）。
@Suite("消息列表的排序、未读与角标")
struct InboxTests {
    func conversation(
        _ id: String, last: Int64, read: Int64? = nil, waiting: Bool = false, lifecycle: String = "idle"
    ) -> SavedConversation {
        SavedConversation(key: key(id), lifecycleState: lifecycle, waitingForInput: waiting, lastMessageAt: last, readMarker: read)
    }

    @Test("按最后活动倒序；等你处理的置顶，彼此之间仍按最后活动倒序；同一时刻按会话 ID 定序")
    func waitingPinnedThenRecent() {
        let ordered = Inbox.ordered([
            conversation("a", last: 300),
            conversation("b", last: 100, waiting: true),
            conversation("c", last: 500),
            conversation("d", last: 200, waiting: true),
            conversation("f", last: 400),
            conversation("e", last: 400),
        ])
        #expect(ordered.map(\.key.conversationID) == ["d", "b", "c", "e", "f", "a"])
    }

    @Test("未读判据：最后活动晚于已读位；从未读过的一律未读；已读位追平即已读")
    func unreadFromReadMarker() {
        #expect(conversation("a", last: 100).isUnread)
        #expect(conversation("a", last: 0).isUnread)
        #expect(conversation("a", last: 200, read: 100).isUnread)
        #expect(!conversation("a", last: 200, read: 200).isUnread)
    }

    @Test("一行的状态：等你处理压过运行中，运行中即「正在输入」，失败单列，其余为空闲")
    func activityPrecedence() {
        #expect(conversation("a", last: 1, waiting: true, lifecycle: "running").activity == .waiting)
        #expect(conversation("a", last: 1, lifecycle: "running").activity == .typing)
        #expect(conversation("a", last: 1, lifecycle: "failed").activity == .failed)
        #expect(conversation("a", last: 1, lifecycle: "idle").activity == .idle)
        #expect(conversation("a", last: 1, lifecycle: "interrupted").activity == .idle)
    }

    @Test("角标两个数：等你处理的条数与未读的条数，各自独立地数")
    func badgeCounts() {
        let badge = MessagesBadge([
            conversation("a", last: 100, read: 100, waiting: true),
            conversation("b", last: 200, read: 100),
            conversation("c", last: 300),
            conversation("d", last: 50, read: 60),
        ])
        #expect(badge == MessagesBadge(waiting: 1, unread: 2))
        #expect(MessagesBadge([]) == MessagesBadge(waiting: 0, unread: 0))
    }
}
