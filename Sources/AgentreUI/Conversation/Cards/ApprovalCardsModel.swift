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

/// 提问卡提交前的核对没过（宿主 canonical.userAsk.errors 的两句）。
public enum QuestionInputError: Sendable, Equatable {
    /// 有一问一个选项都没选。
    case optionRequired
    /// 选了自定义答案却没填字。
    case otherRequired
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
    /// 每问选中的 label（含自定义答案的 `QuestionAnswer.otherLabel`），按点选次序。
    private var selections: [String: [Int: [String]]] = [:]
    /// 每问自定义答案的字。
    private var drafts: [String: [Int: String]] = [:]
    private var inputErrors: [String: QuestionInputError] = [:]
    private var expanded: Set<String> = []

    public init(conversation: SavedConversation, answering: any ApprovalAnswering) {
        self.conversation = conversation
        self.answering = answering
    }

    // MARK: 权限

    /// 转录已落定的照转录（决议帧带着「本会话」这一格）；否则看本机作答走到哪一步。
    /// 别的端先答了的，本机这一答不是结局：等转录里的决议。
    public func state(of request: PermissionRequest) -> ApprovalPermissionState {
        if request.resolved {
            guard request.allowed else { return .denied }
            return request.alwaysAllow ? .allowedForSession : .allowed
        }
        switch permissions[request.requestID] {
        case nil: return .open(submitting: false, failed: false)
        case .sending, .handledElsewhere: return .open(submitting: true, failed: false)
        case .failed: return .open(submitting: false, failed: true)
        case .delivered(.reject): return .denied
        case .delivered(.allowForSession): return .allowedForSession
        case .delivered(.allowOnce): return .allowed
        }
    }

    /// 发出一档处置；送达后落定，没送达回到待处置并标出失败。待处置之外的请求、没有请求号的请求不收。
    public func submit(_ disposition: PermissionDisposition, for request: PermissionRequest) async {
        guard !request.requestID.isEmpty, case .open(submitting: false, _) = state(of: request) else { return }
        permissions[request.requestID] = .sending
        do {
            let delivery = try await answering.submitToolPermission(ToolPermissionReply(
                conversation: conversation.key, peerFingerprint: conversation.peerFingerprint,
                requestID: request.requestID, disposition: disposition
            ))
            permissions[request.requestID] = delivery == .accepted ? .delivered(disposition) : .handledElsewhere
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
        case .sending, .handledElsewhere: return .open(submitting: true)
        case .expired: return .expired
        case .delivered(let skipped): return skipped ? .skipped : .answered
        }
    }

    public func selectedLabels(_ index: Int, of request: QuestionRequest) -> [String] {
        selections[request.requestID]?[index] ?? []
    }

    /// 点一个选项，规则与宿主同：多选时加入或移出；单选时换成它，点的正是已选的那个则取消。
    public func toggleOption(_ label: String, at index: Int, of request: QuestionRequest) {
        let multi = request.questions.indices.contains(index) && request.questions[index].multiSelect
        var labels = selectedLabels(index, of: request)
        if multi {
            if let at = labels.firstIndex(of: label) { labels.remove(at: at) } else { labels.append(label) }
        } else {
            labels = labels.first == label ? [] : [label]
        }
        selections[request.requestID, default: [:]][index] = labels
    }

    /// 自定义答案的字。
    public func answer(_ index: Int, of request: QuestionRequest) -> String {
        drafts[request.requestID]?[index] ?? ""
    }

    /// 填自定义答案，与宿主同：填了字即选中自定义，清空即取消。
    public func setAnswer(_ text: String, at index: Int, of request: QuestionRequest) {
        drafts[request.requestID, default: [:]][index] = text
        let chosen = selectedLabels(index, of: request).contains(QuestionAnswer.otherLabel)
        let wanted = !text.isEmpty
        if wanted != chosen {
            toggleOption(QuestionAnswer.otherLabel, at: index, of: request)
        }
    }

    /// 上一次提交没过核对的原因；没有或已改对提交后为 nil。
    public func inputError(of request: QuestionRequest) -> QuestionInputError? {
        inputErrors[request.requestID]
    }

    /// 可以提交：待作答，且每一问都选了，选了自定义答案的填了字。
    public func canSubmit(_ request: QuestionRequest) -> Bool {
        state(of: request) == .open(submitting: false) && validate(request) == nil
    }

    /// 以每问选中的 label 作答；核对没过则不发出，只记下原因（宿主的两句报错）。
    public func submitAnswers(for request: QuestionRequest) async {
        guard !request.requestID.isEmpty, state(of: request) == .open(submitting: false) else { return }
        if let error = validate(request) {
            inputErrors[request.requestID] = error
            return
        }
        inputErrors[request.requestID] = nil
        let answers = request.questions.indices.map { index in
            QuestionAnswer(questionIndex: index, labels: selectedLabels(index, of: request), otherText: answer(index, of: request))
        }
        await send(request, answers: answers, skipped: false)
    }

    private func validate(_ request: QuestionRequest) -> QuestionInputError? {
        for index in request.questions.indices {
            let labels = selectedLabels(index, of: request)
            if labels.isEmpty { return .optionRequired }
            if labels.contains(QuestionAnswer.otherLabel), answer(index, of: request).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .otherRequired
            }
        }
        return nil
    }

    public func skip(_ request: QuestionRequest) async {
        guard !request.requestID.isEmpty, state(of: request) == .open(submitting: false) else { return }
        await send(request, answers: [], skipped: true)
    }

    /// 与宿主同：没被接收即失效，不再作答。
    private func send(_ request: QuestionRequest, answers: [QuestionAnswer], skipped: Bool) async {
        questions[request.requestID] = .sending
        do {
            let delivery = try await answering.submitAnswer(QuestionReply(
                conversation: conversation.key, peerFingerprint: conversation.peerFingerprint,
                requestID: request.requestID, questions: request.questions.map(\.question), answers: answers, skipped: skipped
            ))
            questions[request.requestID] = delivery == .accepted ? .delivered(skipped: skipped) : .handledElsewhere
            drafts[request.requestID] = nil
            selections[request.requestID] = nil
            inputErrors[request.requestID] = nil
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
    /// 送达了，但别的端先答了：结局等转录里的决议。
    case handledElsewhere
}

/// 本机对一次提问的作答走到哪一步。
private enum QuestionProgress: Equatable {
    case sending
    case expired
    case delivered(skipped: Bool)
    /// 送达了，但别的端先答了：结局等转录里的决议。
    case handledElsewhere
}
