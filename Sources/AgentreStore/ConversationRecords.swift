import Foundation
import SwiftData

/// 已保存会话的一行。键是「发起端指纹 + 会话 ID」（与服务端镜像同一身份）。
@Model
final class ConversationRecord {
    #Unique<ConversationRecord>([\.machineFingerprint, \.conversationID])

    /// 发起端：清单回显的 peer_fingerprint，空时就是承载它的那台机器。
    var machineFingerprint: String
    var conversationID: String
    /// 经哪台机器保存、跟随的：那台机器的通道上到达的帧据它认回这一行。
    var viaFingerprint: String
    var peerFingerprint: String
    var title: String
    var agentSyncID: String
    var cwd: String
    var projectSyncID: String
    var backendType: String
    var lifecycleState: String
    var waitingForInput: Bool
    var lastMessageAt: Int64
    /// 本机自己的游标：已落库的最大帧号。
    var latestSeq: Int64
    var readMarker: Int64?
    /// 清单上这条会话此刻用的模型与思考档位（带默认值：旧库轻量迁移时补空）。
    var providerKey: String = ""
    var modelKey: String = ""
    var reasoningEffort: String = ""

    init(machineFingerprint: String, conversationID: String, viaFingerprint: String) {
        self.machineFingerprint = machineFingerprint
        self.conversationID = conversationID
        self.viaFingerprint = viaFingerprint
        peerFingerprint = ""
        title = ""
        agentSyncID = ""
        cwd = ""
        projectSyncID = ""
        backendType = ""
        lifecycleState = ""
        waitingForInput = false
        lastMessageAt = 0
        latestSeq = 0
        readMarker = nil
    }
}

/// 转录里的一帧：按 (发起端, 会话, seq) 唯一。落的是带号的 wire 通知原件。
@Model
final class FrameRecord {
    #Unique<FrameRecord>([\.machineFingerprint, \.conversationID, \.seq])
    #Index<FrameRecord>([\.machineFingerprint, \.conversationID, \.seq])

    var machineFingerprint: String
    var conversationID: String
    var seq: Int64
    var createtime: Int64
    var payload: Data

    init(machineFingerprint: String, conversationID: String, seq: Int64, createtime: Int64, payload: Data) {
        self.machineFingerprint = machineFingerprint
        self.conversationID = conversationID
        self.seq = seq
        self.createtime = createtime
        self.payload = payload
    }
}
