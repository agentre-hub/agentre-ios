import Foundation

/// 机器会话清单里的一条（wire `SessionSummary` 的领域形状），机器现答的。
public struct MachineSession: Sendable, Equatable, Identifiable {
    public let conversationID: String
    /// 清单里原样回显的发起端指纹；空表示「就是这台机器」。
    public let peerFingerprint: String
    public let title: String
    public let agentSyncID: String
    public let cwd: String
    public let projectSyncID: String
    public let backendType: String
    public let lifecycleState: String
    public let waitingForInput: Bool
    public let latestSeq: Int64
    /// 最后活动时刻，机器时钟上的 Unix 毫秒；0 表示机器没报。
    public let lastMessageAt: Int64

    public var id: String { conversationID }

    public init(
        conversationID: String, peerFingerprint: String = "", title: String = "", agentSyncID: String = "", cwd: String = "",
        projectSyncID: String = "", backendType: String = "", lifecycleState: String = "", waitingForInput: Bool = false,
        latestSeq: Int64 = 0, lastMessageAt: Int64 = 0
    ) {
        self.conversationID = conversationID
        self.peerFingerprint = peerFingerprint
        self.title = title
        self.agentSyncID = agentSyncID
        self.cwd = cwd
        self.projectSyncID = projectSyncID
        self.backendType = backendType
        self.lifecycleState = lifecycleState
        self.waitingForInput = waitingForInput
        self.latestSeq = latestSeq
        self.lastMessageAt = lastMessageAt
    }

    /// 这一行此刻的状态，与消息列表同一套判法。
    public var activity: ConversationActivity {
        if waitingForInput { return .waiting }
        switch lifecycleState {
        case SavedConversation.Lifecycle.running: return .typing
        case SavedConversation.Lifecycle.failed: return .failed
        default: return .idle
        }
    }
}

/// `sessionList` 的一页（新到旧）。
public struct MachineSessionPage: Sendable, Equatable {
    public let sessions: [MachineSession]
    /// 下一页从这里接着要；空 = 这是最后一页。对调用方不透明。
    public let cursor: String
    public let hasMore: Bool

    public init(sessions: [MachineSession], cursor: String, hasMore: Bool) {
        self.sessions = sessions
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

/// `sessionCounts`：那台机器现算的三个数。
public struct MachineSessionCounts: Sendable, Equatable {
    public let total: Int64
    public let running: Int64
    public let waiting: Int64

    public init(total: Int64, running: Int64, waiting: Int64) {
        self.total = total
        self.running = running
        self.waiting = waiting
    }
}

/// 经中继问一台机器要它的会话（通道 `machine:<指纹>`）。适配器在装配层实现。
public protocol MachineSessionSource: Sendable {
    /// 按关键词（机器保底只按标题大小写不敏感地匹配）翻一页；`cursor` 为空从最新的一条起。
    func sessions(on machineFingerprint: String, keyword: String, cursor: String, limit: Int) async throws -> MachineSessionPage
    func counts(on machineFingerprint: String) async throws -> MachineSessionCounts
}
