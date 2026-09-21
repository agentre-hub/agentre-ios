import Foundation

/// 消息列表的排列：等你处理的置顶，其余与置顶内部都按最后活动倒序；同一时刻按会话 ID 定序，
/// 让列表在两次刷新之间不跳。
public enum Inbox {
    public static func ordered(_ conversations: [SavedConversation]) -> [SavedConversation] {
        conversations.sorted { lhs, rhs in
            if lhs.waitingForInput != rhs.waitingForInput { return lhs.waitingForInput }
            if lhs.lastMessageAt != rhs.lastMessageAt { return lhs.lastMessageAt > rhs.lastMessageAt }
            if lhs.key.conversationID != rhs.key.conversationID { return lhs.key.conversationID < rhs.key.conversationID }
            return lhs.key.machineFingerprint < rhs.key.machineFingerprint
        }
    }
}

/// 消息标签上的两个数：等你处理的条数与未读的条数，由本地库里的行现算。
public struct MessagesBadge: Sendable, Equatable {
    public let waiting: Int
    public let unread: Int

    public init(waiting: Int, unread: Int) {
        self.waiting = waiting
        self.unread = unread
    }

    public init(_ conversations: [SavedConversation]) {
        self.init(
            waiting: conversations.count { $0.waitingForInput },
            unread: conversations.count { $0.isUnread }
        )
    }
}
