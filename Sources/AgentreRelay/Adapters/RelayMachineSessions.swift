import AgentreDomain
import AgentreWire
import Foundation

/// 机器详情页的两个中继端口：问一台机器要它的会话清单与计数，以及保存到手机时的
/// attach + pull。一律走 `machine:<指纹>`，以 conversation_id 指明对话。
public actor RelayMachineSessions: MachineSessionSource, MachineSessionTransfer {
    private struct Conversation: Hashable {
        let machine: String
        let conversationID: String
    }

    private let connection: RelayConnection
    /// attach 交回的最高帧号，pull 据它判断本机游标是否越界。
    private var highWater: [Conversation: Int64] = [:]

    public init(connection: RelayConnection) {
        self.connection = connection
    }

    // MARK: MachineSessionSource

    public func sessions(on machineFingerprint: String, keyword: String, cursor: String, limit: Int) async throws -> MachineSessionPage {
        var request = Agentre_Wire_SessionListRequest()
        request.keyword = keyword
        request.cursor = cursor
        request.limit = Int32(clamping: limit)
        let response: Agentre_Wire_SessionListResponse = try await connection.call(machine: machineFingerprint, .sessionList, request)
        return MachineSessionPage(sessions: response.sessions.map(MachineSession.init), cursor: response.cursor, hasMore: response.hasMore_p)
    }

    public func counts(on machineFingerprint: String) async throws -> MachineSessionCounts {
        let response: Agentre_Wire_SessionCountsResponse = try await connection.call(
            machine: machineFingerprint, .sessionCounts, Agentre_Wire_SessionCountsRequest()
        )
        return MachineSessionCounts(total: response.total, running: response.running, waiting: response.waiting)
    }

    // MARK: MachineSessionTransfer

    public func attach(conversationID: String, peerFingerprint: String, on machineFingerprint: String) async throws -> Int64 {
        var request = Agentre_Wire_SessionAttachRequest()
        request.conversationID = conversationID
        request.peerFingerprint = peerFingerprint
        let response: Agentre_Wire_SessionAttachResponse = try await connection.call(machine: machineFingerprint, .sessionAttach, request)
        highWater[Conversation(machine: machineFingerprint, conversationID: conversationID)] = response.latestSeq
        return response.latestSeq
    }

    public func pull(conversationID: String, peerFingerprint: String, after cursor: Int64, on machineFingerprint: String) async throws -> PulledFrames {
        var request = Agentre_Wire_SessionPullRequest()
        request.conversationID = conversationID
        request.peerFingerprint = peerFingerprint
        request.cursor = cursor
        // 游标越过机器报的最高帧号，只说明那边的帧号重新起算了：从头拉，而不是永远什么都拉不到
        // （mirror_svc.dropCursorAboveHighWater）。
        if let latest = highWater[Conversation(machine: machineFingerprint, conversationID: conversationID)], cursor > latest {
            request.cursor = 0
        }
        request.limit = RelayProtocol.pullLimit
        let response: Agentre_Wire_SessionPullResponse = try await connection.call(machine: machineFingerprint, .sessionPull, request)
        let frames = try await relayFailures {
            try response.notifications.map { PulledFrame(seq: $0.seq, createtime: $0.createtime, payload: try $0.payload.serializedData()) }
        }
        return PulledFrames(frames: frames, cursor: response.cursor, hasMore: response.hasMore_p)
    }
}

extension MachineSession {
    init(_ summary: Agentre_Wire_SessionSummary) {
        self.init(
            conversationID: summary.conversationID, peerFingerprint: summary.peerFingerprint, title: summary.title,
            agentSyncID: summary.agentSyncID, cwd: summary.cwd, projectSyncID: summary.projectSyncID,
            backendType: summary.backendType, lifecycleState: summary.lifecycleState,
            waitingForInput: summary.waitingForInput, latestSeq: summary.latestSeq, lastMessageAt: summary.lastMessageAt,
            providerKey: summary.providerKey, modelKey: summary.modelKey, reasoningEffort: summary.reasoningEffort
        )
    }
}
