import AgentreDomain
import Observation

/// 消息列表的状态：读本地库，库一变就地刷新。已读是本机自己的事，乐观改写。
///
/// 搜索是本地的：按标题 / 项目名 / 机器名做大小写不敏感的子串匹配，即输即筛，不发网络请求
/// （规格「01 消息」）。项目名与机器名经 `identity` 查——同一份目录，头像字形也靠它解身份色。
@MainActor
@Observable
public final class MessagesModel {
    /// 置顶与最后活动排好的会话，未搜索时的全表。
    private var allConversations: [SavedConversation] = []
    /// 搜索框里的词；清空即恢复全表。
    public var query = ""

    /// 按 `query` 筛过的会话；`query` 为空时就是全表。
    public var conversations: [SavedConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return allConversations }
        return allConversations.filter { matches($0, needle) }
    }

    /// 消息标签上的两个数，由全表（不受搜索影响）现算。
    public var badge: MessagesBadge { MessagesBadge(allConversations) }

    private let store: any ConversationStore
    private let identity: any IdentityDirectory
    /// 已乐观标成已读、库还没答复的行：期间的刷新不能把它冲回未读。
    private var pendingReads: Set<ConversationKey> = []
    /// 账号的项目树，供头像字形与按项目名搜索；一次都没取到过时为 nil。
    private var projects: [WorkspaceProject]?
    /// 承载机器指纹 → 呈现名，供按机器名搜索；查过一次答不出来的不再重查。
    private var machineNames: [String: String] = [:]

    public init(store: any ConversationStore, identity: any IdentityDirectory = NullIdentityDirectory()) {
        self.store = store
        self.identity = identity
    }

    /// 从本地库读一遍。本地库不走网络，冷启动与离线时同样读得出来；读失败时保留已有的行。
    public func load() async {
        guard let rows = try? await store.conversations() else { return }
        allConversations = Inbox.ordered(rows.map { row in
            guard pendingReads.contains(row.key) else { return row }
            var read = row
            read.readMarker = row.lastMessageAt
            return read
        })
        await refreshIdentity(for: allConversations)
    }

    /// 跟着本地库与身份目录的变动刷新，直到所在任务被取消。项目树与机器名常常晚于列表到达，
    /// 库此时未必再变：不跟着目录，空白字形与按项目名 / 机器名的搜索会一直停在「还不知道」。
    public func follow() async {
        async let library: Void = followStore()
        async let directory: Void = followIdentity()
        _ = await (library, directory)
    }

    private func followStore() async {
        for await _ in await store.changes() { await load() }
    }

    private func followIdentity() async {
        for await _ in await identity.changes() { await load() }
    }

    /// 标记已读：这一行立刻读作已读，再让库记下；库没记下就退回库里的真值。
    public func markRead(_ key: ConversationKey) async {
        guard let index = allConversations.firstIndex(where: { $0.key == key }) else { return }
        allConversations[index].readMarker = allConversations[index].lastMessageAt
        pendingReads.insert(key)
        defer { pendingReads.remove(key) }
        do {
            try await store.markRead(key)
        } catch {
            pendingReads.remove(key)
            await load()
        }
    }

    /// 这条会话该画的头像字形：项目的身份色加首字，不属于项目的中性字形，或项目树还没取到时的空白字形。
    public func glyph(for conversation: SavedConversation) -> IdentityGlyph {
        .project(conversation.projectSyncID, in: projects)
    }

    /// 项目树取一遍；承载机器名逐个补（查过一次答不出来的不再重查——离线时不必每次刷新都再问一遍）。
    private func refreshIdentity(for rows: [SavedConversation]) async {
        projects = await identity.projects()
        for fingerprint in Set(rows.map(\.carrierFingerprint)) where !fingerprint.isEmpty && machineNames[fingerprint] == nil {
            if let name = await identity.machineName(fingerprint: fingerprint) {
                machineNames[fingerprint] = name
            }
        }
    }

    private func matches(_ conversation: SavedConversation, _ needle: String) -> Bool {
        if !conversation.title.isEmpty, conversation.title.localizedCaseInsensitiveContains(needle) { return true }
        if let name = projectName(conversation.projectSyncID), name.localizedCaseInsensitiveContains(needle) { return true }
        if let name = machineNames[conversation.carrierFingerprint], name.localizedCaseInsensitiveContains(needle) { return true }
        return false
    }

    private func projectName(_ syncID: String) -> String? {
        guard !syncID.isEmpty else { return nil }
        return projects?.first { $0.syncID == syncID }?.name
    }
}
