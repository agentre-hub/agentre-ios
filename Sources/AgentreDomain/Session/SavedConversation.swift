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

    /// 机器清单里的一条会话的键：键上记发起端；发起端为空时是承载它的这台机器自己发起的。
    public init(conversationID: String, peerFingerprint: String, via carrier: String) {
        self.init(machineFingerprint: peerFingerprint.isEmpty ? carrier : peerFingerprint, conversationID: conversationID)
    }
}

/// 手机上保存的一条会话的摘要。元数据取自机器的会话清单（机器是权威），
/// `latestSeq` 与 `readMarker` 是本机自己的两格。
public struct SavedConversation: Sendable, Equatable, Identifiable {
    public let key: ConversationKey
    /// 承载它的机器（保存、跟随、打开都经这台的 `machine:` 通道）。会话键上的是发起端，二者不可互相代替。
    public var carrierFingerprint: String
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
    /// 此刻等你处理的那一件事（待批准的命令 / 待回答的问题），取自已落库的帧；
    /// 不在等你处理时为 nil。
    public var pending: PendingInput?
    /// 转录里最近一句正文或用户消息；还没有时为空。
    public var lastText: String
    /// 这条会话此刻用的模型（清单原样）；空 = 机器没报。
    public var providerKey: String
    public var modelKey: String
    /// 这条会话记下的思考档位；空 = 跟随后端配置。
    public var reasoningEffort: String

    public var id: ConversationKey { key }

    public init(
        key: ConversationKey,
        carrierFingerprint: String = "",
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
        readMarker: Int64? = nil,
        pending: PendingInput? = nil,
        lastText: String = "",
        providerKey: String = "",
        modelKey: String = "",
        reasoningEffort: String = ""
    ) {
        self.key = key
        self.carrierFingerprint = carrierFingerprint
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
        self.pending = pending
        self.lastText = lastText
        self.providerKey = providerKey
        self.modelKey = modelKey
        self.reasoningEffort = reasoningEffort
    }

    /// 会话生命周期的取值（与机器、服务端镜像同一套字符串）。
    public enum Lifecycle {
        public static let running = "running"
        public static let idle = "idle"
        public static let failed = "failed"
        public static let interrupted = "interrupted"
    }

    /// 未读判据（规格决策 17）：最后活动时刻晚于已读位即为未读；从未读过的一律未读。
    public var isUnread: Bool {
        guard let readMarker else { return true }
        return lastMessageAt > readMarker
    }

    /// 这一行此刻的状态。
    public var activity: ConversationActivity {
        ConversationActivity(lifecycleState: lifecycleState, waitingForInput: waitingForInput)
    }
}

/// 一条会话此刻的状态，与即时通讯的同名状态是同一件事。
public enum ConversationActivity: Sendable, Equatable {
    /// 对面在等你回：待批准或待回答。
    case waiting
    /// 对端正在产生内容。
    case typing
    case failed
    case idle

    /// 从摘要的两格判出来。等你处理压过运行中：对端停在你这儿，不是在输入。
    public init(lifecycleState: String, waitingForInput: Bool) {
        if waitingForInput {
            self = .waiting
            return
        }
        switch lifecycleState {
        case SavedConversation.Lifecycle.running: self = .typing
        case SavedConversation.Lifecycle.failed: self = .failed
        default: self = .idle
        }
    }
}

/// 等你处理的那一件事。
public enum PendingInput: Sendable, Equatable {
    /// 待批准的工具调用：工具名，与它要跑的命令或要动的文件（取不到时为 nil）。
    case permission(tool: String, detail: String?)
    /// 待回答的问题。
    case question(String)
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
