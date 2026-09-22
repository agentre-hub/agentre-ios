import AgentreDomain
import AgentreRelay
import AgentreStore
import Foundation

/// 连接建立后，本地库里的每条会话经它的承载机 attach、按本机游标补齐，此后到达的帧落库
/// （规格「消息列表」：新到的帧落库并就地反映到列表上）。库里多一条就多跟随一条，少一条就停掉。
///
/// 每一次 attach（首次，以及重连后通道自己重做的那些）的应答都排在那一轮补拉的帧之前到达：
/// 本机游标越过机器的最高帧号就先丢掉库里旧编号的帧，否则重拉的帧都被当成重复；再按机器此刻的
/// 清单刷新摘要——轮次边界帧不带号、补拉不回来，断线期间结束的一轮只有清单说得出来
/// （mirror_svc.catchUp 每轮补齐都 saveSummary）。刷新到的生命周期同时交给 `onLifecycle`：开着的输入区
/// 据它得知那一轮已经收场。
actor ConversationSync {
    private let connection: RelayConnection
    private let store: LocalConversationStore
    private let sessions: RelayMachineSessions
    private let onFailure: @Sendable (ConversationKey, FailureFact?) async -> Void
    private let onLifecycle: @Sendable (ConversationKey, String) async -> Void
    private var following: [ConversationKey: (token: UUID, task: Task<Void, Never>)] = [:]
    private var stopped = false

    /// - Parameters:
    ///   - onFailure: 一条会话跟随不上（机器不在线、版本不等、通道被关……）时的事实；接上后以 nil 清掉。
    ///   - onLifecycle: 每次 attach 后按机器清单刷新到的那条会话此刻的生命周期。
    init(
        connection: RelayConnection, store: LocalConversationStore,
        onFailure: @escaping @Sendable (ConversationKey, FailureFact?) async -> Void,
        onLifecycle: @escaping @Sendable (ConversationKey, String) async -> Void
    ) {
        self.connection = connection
        self.store = store
        sessions = RelayMachineSessions(connection: connection)
        self.onFailure = onFailure
        self.onLifecycle = onLifecycle
    }

    /// 跟着库的变化跟随，直到所在任务被取消。
    func run() async {
        let changes = await store.changes()
        await resync()
        for await _ in changes {
            await resync()
        }
    }

    /// 对库里还没在跟随的会话开始跟随（回到前台、点重试时也调它）。读库之后不再挂起，
    /// 两次并发的 resync 不会为同一条会话各起一个跟随。
    func resync() async {
        guard !stopped, let targets = try? await store.followTargets(), !stopped else { return }
        let keys = Set(targets.map(\.key))
        for (key, entry) in following where !keys.contains(key) {
            entry.task.cancel()
            following[key] = nil
        }
        for target in targets where following[target.key] == nil {
            let token = UUID()
            following[target.key] = (token, Task {
                await self.follow(target)
                await self.finished(target.key, token)
            })
        }
    }

    func stop() {
        stopped = true
        for entry in following.values { entry.task.cancel() }
        following = [:]
    }

    /// 只清掉自己那一格：会话删了又存回来时，旧的跟随收场不能抹掉新的那一个。
    private func finished(_ key: ConversationKey, _ token: UUID) {
        guard following[key]?.token == token else { return }
        following[key] = nil
    }

    private func follow(_ target: FollowTarget) async {
        let key = target.key
        let channel = await connection.channel(for: .machine(fingerprint: target.carrier))
        let events = await channel.events(conversationID: key.conversationID)
        do {
            let cursor = try await store.latestSeq(key)
            _ = try await channel.attach(conversationID: key.conversationID, peerFingerprint: target.peerFingerprint, after: cursor)
        } catch {
            await onFailure(key, AppFailure.fact(for: error))
            return
        }
        await onFailure(key, nil)
        for await event in events {
            switch event {
            case .attached(let latestSeq):
                if let latestSeq { try? await store.rewind(key, highWater: latestSeq) }
                await refreshSummary(target)
            case .notification(let notification):
                try? await store.record([IncomingFrame(notification)], via: target.carrier)
            }
        }
        guard !Task.isCancelled else { return }
        // 通道被关掉（服务端判死、版本不等）：如实说出来；下一次 resync（回前台、点重试、库变）再接——
        // 版本不等的那台机器不再握手，再接只会再说一遍要更新 App。
        let closed: RelayCallError = await channel.status == .updateRequired ? .updateRequired : .channelClosed
        await onFailure(key, AppFailure.fact(for: closed))
    }

    /// 按机器此刻的清单刷新这一条的摘要（生命周期、等你处理、标题……）。问不到就留着旧的；
    /// 应答到时这一条已不在库里（删掉了）就不再把它收回来。
    private func refreshSummary(_ target: FollowTarget) async {
        guard let session = try? await sessions.session(target.key, on: target.carrier),
              (try? await store.refresh(session, via: target.carrier)) == true
        else { return }
        await onLifecycle(target.key, session.lifecycleState)
    }
}
