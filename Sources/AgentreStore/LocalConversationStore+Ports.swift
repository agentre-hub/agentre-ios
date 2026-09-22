import AgentreDomain
import AgentreWire
import Foundation

/// 领域写入端口落到本地库：认得 wire 的这一侧把领域形状转成库自己的。
extension LocalConversationStore: ConversationSaving {
    /// 把机器清单里的一条收进库（已在库里则以它刷新摘要）；`machineFingerprint` 是承载机。
    @discardableResult
    public func save(_ session: MachineSession, via machineFingerprint: String) throws -> ConversationKey {
        var summary = Agentre_Wire_SessionSummary()
        summary.conversationID = session.conversationID
        summary.peerFingerprint = session.peerFingerprint
        summary.title = session.title
        summary.agentSyncID = session.agentSyncID
        summary.cwd = session.cwd
        summary.projectSyncID = session.projectSyncID
        summary.backendType = session.backendType
        summary.lifecycleState = session.lifecycleState
        summary.waitingForInput = session.waitingForInput
        summary.latestSeq = session.latestSeq
        summary.lastMessageAt = session.lastMessageAt
        summary.providerKey = session.providerKey
        summary.modelKey = session.modelKey
        summary.reasoningEffort = session.reasoningEffort
        return try save(summary, via: machineFingerprint)
    }

    /// 以机器此刻的清单刷新一条**已在库里**的会话。它已不在库里（跟随在途时被删掉、登出清空了）就什么都不做：
    /// 库里只收手机新建的与用户主动保存的（规格决策 16），跟随不往库里收东西。交回是否刷新了。
    @discardableResult
    public func refresh(_ session: MachineSession, via machineFingerprint: String) throws -> Bool {
        let owner = session.peerFingerprint.isEmpty ? machineFingerprint : session.peerFingerprint
        guard try conversation(ConversationKey(machineFingerprint: owner, conversationID: session.conversationID)) != nil else {
            return false
        }
        try save(session, via: machineFingerprint)
        return true
    }

    /// 补齐拉回的一批帧：载体上带着源端时刻（0 照录），所以不是实时帧、不跟随摘要。
    public func record(_ frames: [PulledFrame], into key: ConversationKey, via machineFingerprint: String) throws {
        let incoming = try frames.map { frame in
            IncomingFrame(
                conversationID: key.conversationID, seq: frame.seq, createtime: frame.createtime,
                payload: try Agentre_Wire_RpcNotification(serializedBytes: frame.payload)
            )
        }
        try record(incoming, into: key)
    }
}

extension LocalConversationStore {
    /// 手机新建、已在机器上跑起来的对话：发起端是本机（`origin`，与机器报的 peer_fingerprint 同一个），
    /// 承载机是派到的那台，处于运行中。于是机器清单里的这一条刷新的是同一行，在机器详情页再保存也不多出一行。
    public func record(_ conversation: StartedConversation, origin: String) throws -> ConversationKey {
        var summary = Agentre_Wire_SessionSummary()
        summary.conversationID = conversation.conversationID
        summary.peerFingerprint = origin
        summary.title = conversation.title
        summary.agentSyncID = conversation.agentSyncID
        summary.projectSyncID = conversation.projectSyncID
        summary.cwd = conversation.cwd
        summary.backendType = conversation.backendType
        summary.lifecycleState = SavedConversation.Lifecycle.running
        // 话是本机此刻说的：最后活动就是此刻（排在列表最前），也已读过。
        summary.lastMessageAt = now()
        let key = try save(summary, via: conversation.machineFingerprint)
        try markRead(key)
        return key
    }
}

/// 新建对话的落库端口：以本机设备指纹为发起端落进本地库。
public struct StartedConversationRecorder: StartedConversationRecording {
    public let store: LocalConversationStore
    /// 本机的设备指纹。
    public let origin: String

    public init(store: LocalConversationStore, origin: String) {
        self.store = store
        self.origin = origin
    }

    public func record(_ conversation: StartedConversation) async throws -> ConversationKey {
        try await store.record(conversation, origin: origin)
    }
}
