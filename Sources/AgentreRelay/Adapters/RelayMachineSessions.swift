import AgentreDomain
import AgentreWire
import Foundation

/// 机器详情页的两个中继端口：问一台机器要它的会话清单与计数，以及保存到手机时的
/// attach + pull。一律走 `machine:<指纹>`，以 conversation_id 指明对话。
public actor RelayMachineSessions: MachineSessionSource, MachineSessionTransfer {
    private let connection: RelayConnection
    /// 本机（调用方）的设备指纹。
    private let caller: String

    public init(connection: RelayConnection, caller: String) {
        self.connection = connection
        self.caller = caller
    }

    // MARK: MachineSessionSource

    public func sessions(on machineFingerprint: String, keyword: String, cursor: String, limit: Int) async throws -> MachineSessionPage {
        var request = Agentre_Wire_SessionListRequest()
        request.keyword = keyword
        request.cursor = cursor
        request.limit = Int32(clamping: limit)
        let response: Agentre_Wire_SessionListResponse = try await connection.call(machine: machineFingerprint, .sessionList, request)
        return MachineSessionPage(
            sessions: response.sessions.map(domainSession), cursor: response.cursor, hasMore: response.hasMore_p, total: response.total
        )
    }

    public func counts(on machineFingerprint: String) async throws -> MachineSessionCounts {
        let response: Agentre_Wire_SessionCountsResponse = try await connection.call(
            machine: machineFingerprint, .sessionCounts, Agentre_Wire_SessionCountsRequest()
        )
        return MachineSessionCounts(total: response.total, running: response.running, waiting: response.waiting)
    }

    /// 点名问这台机器要一条会话此刻的摘要（清单按 conversation_ids 收窄）；它已不在那台机器上时为 nil。
    public func session(_ key: ConversationKey, on machineFingerprint: String) async throws -> MachineSession? {
        var request = Agentre_Wire_SessionListRequest()
        request.conversationIds = [key.conversationID]
        let response: Agentre_Wire_SessionListResponse = try await connection.call(machine: machineFingerprint, .sessionList, request)
        return response.sessions.map(domainSession).first {
            ConversationKey(conversationID: $0.conversationID, peerFingerprint: $0.peerFingerprint, via: machineFingerprint) == key
        }
    }

    /// 清单里的一行换成领域形状，发起端认回本机。
    ///
    /// agentred 只把发起端标在别的对端发起的会话上，调用方自己发起的那行 peer_fingerprint 为空
    /// （agentre/internal/daemon/handlers/session_catchup.go 的 List：`row.PeerFingerprint != peer`）；
    /// 桌面端作承载机时则一律报它自己的指纹。所以空发起端就是本机：补上本机指纹，手机新建的对话
    /// 在机器详情里读作已保存、再保存也落回同一行。
    private func domainSession(_ summary: Agentre_Wire_SessionSummary) -> MachineSession {
        var summary = summary
        if summary.peerFingerprint.isEmpty { summary.peerFingerprint = caller }
        return MachineSession(summary)
    }

    // MARK: MachineSessionTransfer

    /// 游标越过最高帧号时的回退归调用方（装配层在本地库上一并丢掉旧编号的帧），这里只报数。
    public func attach(conversationID: String, peerFingerprint: String, on machineFingerprint: String) async throws -> Int64? {
        var request = Agentre_Wire_SessionAttachRequest()
        request.conversationID = conversationID
        request.peerFingerprint = peerFingerprint
        let channel = await connection.channel(for: .machine(fingerprint: machineFingerprint))
        return try await relayFailures { () async throws -> Int64? in
            do {
                let response: Agentre_Wire_SessionAttachResponse = try await channel.call(.sessionAttach, request)
                return response.latestSeq
            } catch RelayCallError.rejected(let code) where code == RelayProtocol.errorCodeNoActiveTurn {
                // 那一轮的进程已随上一个对端进程消亡：接不回实时流，历史照拉（mirror_svc.catchUp）。
                return nil
            }
        }
    }

    public func pull(conversationID: String, peerFingerprint: String, after cursor: Int64, on machineFingerprint: String) async throws -> PulledFrames {
        var request = Agentre_Wire_SessionPullRequest()
        request.conversationID = conversationID
        request.peerFingerprint = peerFingerprint
        request.cursor = cursor
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
