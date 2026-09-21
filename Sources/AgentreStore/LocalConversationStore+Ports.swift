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
        return try save(summary, via: machineFingerprint)
    }

    /// 补齐拉回的一批帧：载体上带着源端时刻（0 照录），所以不是实时帧、不跟随摘要。
    public func record(_ frames: [PulledFrame], into key: ConversationKey, via machineFingerprint: String) throws {
        let incoming = try frames.map { frame in
            IncomingFrame(
                conversationID: key.conversationID, seq: frame.seq, createtime: frame.createtime,
                payload: try Agentre_Wire_RpcNotification(serializedBytes: frame.payload)
            )
        }
        try record(incoming, via: machineFingerprint)
    }
}

extension LocalConversationStore: StartedConversationRecording {
    /// 手机新建、已在机器上跑起来的对话：以承载它的机器为发起端与承载机落库，处于运行中。
    public func record(_ conversation: StartedConversation) throws -> ConversationKey {
        var summary = Agentre_Wire_SessionSummary()
        summary.conversationID = conversation.conversationID
        summary.title = conversation.title
        summary.agentSyncID = conversation.agentSyncID
        summary.projectSyncID = conversation.projectSyncID
        summary.cwd = conversation.cwd
        summary.backendType = conversation.backendType
        summary.lifecycleState = SavedConversation.Lifecycle.running
        return try save(summary, via: conversation.machineFingerprint)
    }
}
