import AgentreDomain
import AgentreRelay
import AgentreStore
import Foundation

// 中继与本地库之间的几行胶水：二者互不认识（AgentreStore 不能 import AgentreRelay），在这里接上。

extension IncomingFrame {
    /// 中继通道交出的一条通知原样转成库的入帧。实时帧的载体上没有源端时刻（nil）——
    /// 那正是本地库认「实时帧」的判据（只有它们跟随摘要），这里不补。
    init(_ notification: RelayNotification) {
        self.init(
            conversationID: notification.conversationID, seq: notification.seq,
            createtime: notification.createtime, payload: notification.payload
        )
    }
}

/// 保存到手机时的 attach：机器报的最高帧号低于本机游标，就在同一步把本机那条会话的旧编号帧
/// 丢掉、游标归零（`LocalConversationStore.rewind`），随后的 pull 从头落库而不被当成重复。
struct RewindingTransfer: MachineSessionTransfer {
    let inner: any MachineSessionTransfer
    let store: LocalConversationStore

    func attach(conversationID: String, peerFingerprint: String, on machineFingerprint: String) async throws -> Int64 {
        let highWater = try await inner.attach(conversationID: conversationID, peerFingerprint: peerFingerprint, on: machineFingerprint)
        let key = ConversationKey(
            machineFingerprint: peerFingerprint.isEmpty ? machineFingerprint : peerFingerprint, conversationID: conversationID
        )
        try await store.rewind(key, highWater: highWater)
        return highWater
    }

    func pull(conversationID: String, peerFingerprint: String, after cursor: Int64, on machineFingerprint: String) async throws -> PulledFrames {
        try await inner.pull(conversationID: conversationID, peerFingerprint: peerFingerprint, after: cursor, on: machineFingerprint)
    }
}

/// 转录的中继端口，外加把实时帧里的回合事件递给输入区。只看实时帧（不带源端时刻）：
/// 补齐拉回的历史里那些早已结束的回合不能再触发一次轮末接续。
struct TurnFeedingTranscript: TranscriptRelay {
    let inner: any TranscriptRelay
    let feed: @Sendable (TurnSignal) async -> Void

    func pull(_ key: ConversationKey, peerFingerprint: String, cursor: Int64, limit: Int) async throws -> TranscriptPage {
        try await inner.pull(key, peerFingerprint: peerFingerprint, cursor: cursor, limit: limit)
    }

    func attach(_ key: ConversationKey, peerFingerprint: String) async throws -> AsyncStream<LiveTranscriptFrame> {
        let frames = try await inner.attach(key, peerFingerprint: peerFingerprint)
        let feed = feed
        let (stream, continuation) = AsyncStream<LiveTranscriptFrame>.makeStream()
        let forward = Task {
            for await frame in frames {
                continuation.yield(frame)
                if frame.createtime == 0, let signal = TurnSignal(payload: frame.payload) {
                    await feed(signal)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in forward.cancel() }
        return stream
    }
}

/// 执行端报的权限档位（runtimeCapabilities），经承载机的 `machine:` 通道问。
extension RelayChannel: WireCalling {}

extension RelayConnection {
    func permissionModes(backendType: String, on machineFingerprint: String) async throws -> PermissionModes {
        let channel = await channel(for: .machine(fingerprint: machineFingerprint))
        do {
            return try await PermissionModes.query(backendType: backendType, via: channel)
        } catch let error as RelayCallError {
            throw RelayFailure(error)
        }
    }
}
