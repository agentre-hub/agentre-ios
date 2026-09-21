import AgentreDomain
import Foundation
import Observation

/// 一张权限卡此刻的样子。
public enum ApprovalPermissionState: Sendable, Equatable {
    /// 待处置；`failed` = 上一次作答没送达。
    case open(submitting: Bool, failed: Bool)
    case allowed
    case allowedForSession
    case denied
}

/// 一张提问卡此刻的样子。
public enum ApprovalQuestionState: Sendable, Equatable {
    case open(submitting: Bool)
    case answered
    case skipped
    /// 作答没被接收。
    case expired
}

/// 一条会话里全部审批与提问卡片的本地状态：作答经端口发出，送达后卡片落定。
/// 由装配层按会话建一个，交给转录的卡片插入点；卡片行被列表回收重建也不丢状态。
@MainActor
@Observable
public final class ApprovalCardsModel {
    public let conversation: SavedConversation
    @ObservationIgnored private let answering: any ApprovalAnswering
    private var permissions: [String: PermissionProgress] = [:]
    private var questions: [String: QuestionProgress] = [:]
    private var drafts: [String: [Int: String]] = [:]
    private var expanded: Set<String> = []

    public init(conversation: SavedConversation, answering: any ApprovalAnswering) {
        self.conversation = conversation
        self.answering = answering
    }

    // MARK: 权限

    /// 转录已落定的照转录；否则看本机作答走到哪一步。转录不带「本会话」这一格，
    /// 本机点的是本会话始终允许时据此补上。
    public func state(of request: PermissionRequest) -> ApprovalPermissionState {
        let local = permissions[request.requestID]
        if request.resolved {
            guard request.allowed else { return .denied }
            return local == .delivered(.allowForSession) ? .allowedForSession : .allowed
        }
        switch local {
        case nil: return .open(submitting: false, failed: false)
        case .sending: return .open(submitting: true, failed: false)
        case .failed: return .open(submitting: false, failed: true)
        case .delivered(.reject): return .denied
        case .delivered(.allowForSession): return .allowedForSession
        case .delivered(.allowOnce): return .allowed
        }
    }

    /// 发出一档处置；送达后落定，没送达回到待处置并标出失败。待处置之外的请求不收。
    public func submit(_ disposition: PermissionDisposition, for request: PermissionRequest) async {
        guard case .open(submitting: false, _) = state(of: request) else { return }
        permissions[request.requestID] = .sending
        do {
            try await answering.submitToolPermission(ToolPermissionReply(
                conversation: conversation.key, peerFingerprint: conversation.peerFingerprint,
                requestID: request.requestID, disposition: disposition
            ))
            permissions[request.requestID] = .delivered(disposition)
        } catch {
            permissions[request.requestID] = .failed
        }
    }

    // MARK: 提问

    public func state(of request: QuestionRequest) -> ApprovalQuestionState {
        let local = questions[request.requestID]
        if request.answered { return local == .delivered(skipped: true) ? .skipped : .answered }
        switch local {
        case nil: return .open(submitting: false)
        case .sending: return .open(submitting: true)
        case .expired: return .expired
        case .delivered(let skipped): return skipped ? .skipped : .answered
        }
    }

    public func answer(_ index: Int, of request: QuestionRequest) -> String {
        drafts[request.requestID]?[index] ?? ""
    }

    public func setAnswer(_ text: String, at index: Int, of request: QuestionRequest) {
        drafts[request.requestID, default: [:]][index] = text
    }

    /// 每一问都填了（去掉首尾空白后非空）才能提交。
    public func canSubmit(_ request: QuestionRequest) -> Bool {
        guard state(of: request) == .open(submitting: false) else { return false }
        return request.questions.indices.allSatisfy { !answer($0, of: request).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 以自填答案作答（宿主的 __other__ 标签）。
    public func submitAnswers(for request: QuestionRequest) async {
        guard canSubmit(request) else { return }
        let answers = request.questions.indices.map { index in
            QuestionAnswer(questionIndex: index, labels: [QuestionAnswer.otherLabel], otherText: answer(index, of: request))
        }
        await send(request, answers: answers, skipped: false)
    }

    public func skip(_ request: QuestionRequest) async {
        guard state(of: request) == .open(submitting: false) else { return }
        await send(request, answers: [], skipped: true)
    }

    /// 与宿主同：没被接收即失效，不再作答。
    private func send(_ request: QuestionRequest, answers: [QuestionAnswer], skipped: Bool) async {
        questions[request.requestID] = .sending
        do {
            try await answering.submitAnswer(QuestionReply(
                conversation: conversation.key, peerFingerprint: conversation.peerFingerprint,
                requestID: request.requestID, questions: request.questions, answers: answers, skipped: skipped
            ))
            questions[request.requestID] = .delivered(skipped: skipped)
            drafts[request.requestID] = nil
        } catch {
            questions[request.requestID] = .expired
        }
    }

    // MARK: 展开

    public func isExpanded(_ requestID: String) -> Bool { expanded.contains(requestID) }

    public func toggleExpanded(_ requestID: String) {
        if expanded.contains(requestID) { expanded.remove(requestID) } else { expanded.insert(requestID) }
    }
}

/// 本机对一条权限请求的作答走到哪一步。
private enum PermissionProgress: Equatable {
    case sending
    case failed
    case delivered(PermissionDisposition)
}

/// 本机对一次提问的作答走到哪一步。
private enum QuestionProgress: Equatable {
    case sending
    case expired
    case delivered(skipped: Bool)
}
