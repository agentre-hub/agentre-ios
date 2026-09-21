import AgentreDomain
import AgentreWire
import Foundation

/// 转录的两个中继动作：向承载会话的机器补拉历史（session.pull），与接上实时帧
/// （session.attach 之后，经同一条机器通道投递）。
public struct RelayTranscript: TranscriptRelay {
    private let connection: RelayConnection
    private let carrier: RelayCarrier

    /// - Parameter carrier: 会话经哪台机器走；默认是会话键上的那台。
    public init(connection: RelayConnection, carrier: @escaping RelayCarrier = { $0.machineFingerprint }) {
        self.connection = connection
        self.carrier = carrier
    }

    public func pull(_ key: ConversationKey, peerFingerprint: String, cursor: Int64, limit: Int) async throws -> TranscriptPage {
        var request = Agentre_Wire_SessionPullRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.cursor = cursor
        request.limit = Int32(clamping: limit)
        let response: Agentre_Wire_SessionPullResponse = try await connection.call(machine: await carrier(key), .sessionPull, request)
        let frames = try await relayFailures {
            try response.notifications.map { TranscriptFrame(seq: $0.seq, createtime: $0.createtime, payload: try $0.payload.serializedData()) }
        }
        return TranscriptPage(frames: frames, cursor: response.cursor, hasMore: response.hasMore_p, oldestSeq: response.oldestSeq)
    }

    /// 先订阅再 attach，补齐拉回的帧与此后的实时帧都从这条流出来；重连后的重新 attach 与补齐由通道自己做。
    /// 补齐帧带源端 createtime（可能是 0），实时帧与预览帧不带（nil）——任务 4 的实时判据就是它。
    public func attach(_ key: ConversationKey, peerFingerprint: String, after cursor: Int64) async throws -> AsyncStream<LiveTranscriptFrame> {
        let channel = await connection.channel(for: .machine(fingerprint: await carrier(key)))
        let subscription = await channel.subscribe(conversationID: key.conversationID)
        _ = try await relayFailures {
            try await channel.attach(conversationID: key.conversationID, peerFingerprint: peerFingerprint, after: cursor)
        }
        let (stream, continuation) = AsyncStream<LiveTranscriptFrame>.makeStream()
        let forward = Task {
            for await notification in subscription {
                guard let payload = try? notification.payload.serializedData() else { continue }
                continuation.yield(LiveTranscriptFrame(seq: notification.seq, createtime: notification.createtime, payload: payload))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in forward.cancel() }
        return stream
    }
}
