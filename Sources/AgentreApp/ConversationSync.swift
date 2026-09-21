import AgentreDomain
import AgentreRelay
import AgentreStore
import Foundation

/// 连接建立后，本地库里的每条会话经它的承载机 attach、按本机游标补齐，此后到达的帧落库
/// （规格「消息列表」：新到的帧落库并就地反映到列表上）。库里多一条就多跟随一条，少一条就停掉。
///
/// 游标回退在这里的同一步做完：先订阅（补齐期间的帧在流里等着），attach 交回机器的最高帧号，
/// 本机游标越过它就先丢掉库里旧编号的帧，再把流里的帧落库——否则重拉的帧都被当成重复。
actor ConversationSync {
    private let connection: RelayConnection
    private let store: LocalConversationStore
    private let onFailure: @Sendable (ConversationKey, FailureFact?) async -> Void
    private var following: [ConversationKey: Task<Void, Never>] = [:]
    private var stopped = false

    /// - Parameter onFailure: 一条会话跟随不上（机器不在线、版本不等……）时的事实；接上后以 nil 清掉。
    init(
        connection: RelayConnection, store: LocalConversationStore,
        onFailure: @escaping @Sendable (ConversationKey, FailureFact?) async -> Void
    ) {
        self.connection = connection
        self.store = store
        self.onFailure = onFailure
    }

    /// 跟着库的变化跟随，直到所在任务被取消。
    func run() async {
        let changes = await store.changes()
        await resync()
        for await _ in changes {
            await resync()
        }
    }

    /// 对库里还没在跟随的会话开始跟随（回到前台、点重试时也调它）。
    func resync() async {
        guard !stopped, let saved = try? await store.conversations() else { return }
        let keys = Set(saved.map(\.key))
        for (key, task) in following where !keys.contains(key) {
            task.cancel()
            following[key] = nil
        }
        for conversation in saved where following[conversation.key] == nil {
            guard let carrier = try? await store.carrier(of: conversation.key) else { continue }
            let key = conversation.key
            following[key] = Task {
                await self.follow(key, peerFingerprint: conversation.peerFingerprint, carrier: carrier)
                await self.finished(key)
            }
        }
    }

    func stop() {
        stopped = true
        for task in following.values { task.cancel() }
        following = [:]
    }

    private func finished(_ key: ConversationKey) {
        following[key] = nil
    }

    private func follow(_ key: ConversationKey, peerFingerprint: String, carrier: String) async {
        let channel = await connection.channel(for: .machine(fingerprint: carrier))
        let frames = await channel.subscribe(conversationID: key.conversationID)
        do {
            let cursor = try await store.latestSeq(key)
            let attached = try await channel.attach(conversationID: key.conversationID, peerFingerprint: peerFingerprint, after: cursor)
            try await store.rewind(key, highWater: attached.latestSeq)
        } catch {
            await onFailure(key, AppFailure.fact(for: error))
            return
        }
        await onFailure(key, nil)
        for await notification in frames {
            try? await store.record([IncomingFrame(notification)], via: carrier)
        }
    }
}
