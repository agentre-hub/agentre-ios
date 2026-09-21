import Foundation

/// 本地库里一条会话的身份：**发起它的那台机器**的指纹 + 那台机器自己分配的会话 ID。
///
/// 会话 ID 由各机器本地分配、删除后还会复用，单靠它在两台机器之间并不唯一；服务端镜像
/// 同样以「发起端 + 会话 ID」为键（mirror_svc 的 Identity 一节），这里跟着同一条。
public struct ConversationKey: Sendable, Hashable {
    public let machineFingerprint: String
    public let conversationID: String

    public init(machineFingerprint: String, conversationID: String) {
        self.machineFingerprint = machineFingerprint
        self.conversationID = conversationID
    }
}

/// 手机上保存的一条会话的摘要。元数据取自机器的会话清单（机器是权威），
/// `latestSeq` 与 `readMarker` 是本机自己的两格。
public struct SavedConversation: Sendable, Equatable, Identifiable {
    public let key: ConversationKey
    /// 清单里原样回显的发起端指纹；空表示「就是承载它的那台机器」。attach / pull 时原样带上。
    public var peerFingerprint: String
    public var title: String
    public var agentSyncID: String
    public var cwd: String
    public var projectSyncID: String
    public var backendType: String
    public var lifecycleState: String
    public var waitingForInput: Bool
    /// 最后活动时刻，机器时钟上的 Unix 毫秒；0 表示机器没报。
    public var lastMessageAt: Int64
    /// 本机已落库的最大帧号：补齐从它之后接着拉。
    public var latestSeq: Int64
    /// 已读位：标记已读那一刻看到的最后活动时刻。nil = 从未读过。
    public var readMarker: Int64?

    public var id: ConversationKey { key }

    public init(
        key: ConversationKey,
        peerFingerprint: String = "",
        title: String = "",
        agentSyncID: String = "",
        cwd: String = "",
        projectSyncID: String = "",
        backendType: String = "",
        lifecycleState: String = "",
        waitingForInput: Bool = false,
        lastMessageAt: Int64 = 0,
        latestSeq: Int64 = 0,
        readMarker: Int64? = nil
    ) {
        self.key = key
        self.peerFingerprint = peerFingerprint
        self.title = title
        self.agentSyncID = agentSyncID
        self.cwd = cwd
        self.projectSyncID = projectSyncID
        self.backendType = backendType
        self.lifecycleState = lifecycleState
        self.waitingForInput = waitingForInput
        self.lastMessageAt = lastMessageAt
        self.latestSeq = latestSeq
        self.readMarker = readMarker
    }

    /// 未读判据（规格决策 17）：最后活动时刻晚于已读位即为未读；从未读过的一律未读。
    public var isUnread: Bool {
        guard let readMarker else { return true }
        return lastMessageAt > readMarker
    }
}

/// 转录里的一帧持久帧，按 `seq` 排序。
public struct TranscriptFrame: Sendable, Equatable {
    public let seq: Int64
    /// 源端时钟上的发生时刻（Unix 毫秒）；0 表示不知道，读作「不显示时间」。
    public let createtime: Int64
    /// 这一帧的 wire 通知（`RpcNotification` 的 protobuf 字节，帧号已盖进去）。
    /// 领域层不解码它：解码归认得 wire 的那一层。
    public let payload: Data

    public init(seq: Int64, createtime: Int64, payload: Data) {
        self.seq = seq
        self.createtime = createtime
        self.payload = payload
    }
}
