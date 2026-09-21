import AgentreDomain
import Observation

/// 消息列表的状态：读本地库，库一变就地刷新。已读是本机自己的事，乐观改写。
@MainActor
@Observable
public final class MessagesModel {
    /// 置顶与最后活动排好的会话。
    public private(set) var conversations: [SavedConversation] = []

    /// 消息标签上的两个数，由此刻的行现算。
    public var badge: MessagesBadge { MessagesBadge(conversations) }

    private let store: any ConversationStore
    /// 已乐观标成已读、库还没答复的行：期间的刷新不能把它冲回未读。
    private var pendingReads: Set<ConversationKey> = []

    public init(store: any ConversationStore) {
        self.store = store
    }

    /// 从本地库读一遍。本地库不走网络，冷启动与离线时同样读得出来；读失败时保留已有的行。
    public func load() async {
        guard let rows = try? await store.conversations() else { return }
        conversations = Inbox.ordered(rows.map { row in
            guard pendingReads.contains(row.key) else { return row }
            var read = row
            read.readMarker = row.lastMessageAt
            return read
        })
    }

    /// 跟着本地库的变动刷新，直到所在任务被取消。
    public func follow() async {
        for await _ in await store.changes() {
            await load()
        }
    }

    /// 标记已读：这一行立刻读作已读，再让库记下；库没记下就退回库里的真值。
    public func markRead(_ key: ConversationKey) async {
        guard let index = conversations.firstIndex(where: { $0.key == key }) else { return }
        conversations[index].readMarker = conversations[index].lastMessageAt
        pendingReads.insert(key)
        defer { pendingReads.remove(key) }
        do {
            try await store.markRead(key)
        } catch {
            pendingReads.remove(key)
            await load()
        }
    }
}
