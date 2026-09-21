import Foundation

/// 工具权限的三档处置，按承诺范围由小到大排列（界面从左到右即此顺序）。
/// 档位与措辞取自既有宿主（agentre-ui 的 tool-permission 卡片），不自创。
public enum PermissionDisposition: Sendable, Equatable, CaseIterable {
    /// 拒绝：allow=false。
    case reject
    /// 本会话始终允许：allow=true, always_allow_session=true。
    case allowForSession
    /// 仅本次允许：allow=true, always_allow_session=false。
    case allowOnce

    public var allow: Bool { self != .reject }
    public var alwaysAllowSession: Bool { self == .allowForSession }
}

/// 对一条工具权限请求的作答（runtimeSubmitToolPermission）。
public struct ToolPermissionReply: Sendable, Equatable {
    /// 会话身份：`machineFingerprint` 给出通道 `machine:<指纹>`，`conversationID` 即请求里的 conversation_id。
    public var conversation: ConversationKey
    /// 会话清单里回显的发起端指纹，原样带进请求的 peer_fingerprint。
    public var peerFingerprint: String
    public var requestID: String
    public var disposition: PermissionDisposition

    public init(conversation: ConversationKey, peerFingerprint: String, requestID: String, disposition: PermissionDisposition) {
        self.conversation = conversation
        self.peerFingerprint = peerFingerprint
        self.requestID = requestID
        self.disposition = disposition
    }
}

/// 一问的回答（线上的 AskAnswer）。
public struct QuestionAnswer: Sendable, Equatable {
    /// 自填答案的标签，与后端 canonical.OtherAnswerLabel 对齐。
    public static let otherLabel = "__other__"

    public var questionIndex: Int
    public var labels: [String]
    public var otherText: String

    public init(questionIndex: Int, labels: [String], otherText: String) {
        self.questionIndex = questionIndex
        self.labels = labels
        self.otherText = otherText
    }
}

/// 对一次 agent 提问的作答（runtimeSubmitAnswer）。跳过时 `answers` 为空。
public struct QuestionReply: Sendable, Equatable {
    public var conversation: ConversationKey
    public var peerFingerprint: String
    public var requestID: String
    /// 原样回带的问题文本。
    public var questions: [String]
    public var answers: [QuestionAnswer]
    public var skipped: Bool

    public init(conversation: ConversationKey, peerFingerprint: String, requestID: String, questions: [String], answers: [QuestionAnswer], skipped: Bool) {
        self.conversation = conversation
        self.peerFingerprint = peerFingerprint
        self.requestID = requestID
        self.questions = questions
        self.answers = answers
        self.skipped = skipped
    }
}

/// 审批与提问的作答经宿主既有 RPC 发出：通道一律是 `machine:<承载机器指纹>`，
/// 请求里以 conversation_id 指明对话。中继适配器归装配层。抛错即没送达。
public protocol ApprovalAnswering: Sendable {
    func submitToolPermission(_ reply: ToolPermissionReply) async throws
    func submitAnswer(_ reply: QuestionReply) async throws
}
