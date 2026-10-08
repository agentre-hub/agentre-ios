import AgentreDomain
import AgentreWire
import Foundation

/// 审批与提问的作答：经承载机的 `machine:` 通道发宿主既有的两个 RPC，以 conversation_id 指明对话。
/// 对端答「已经处理过了」（别的端先答了）也算送达：那一问确实不再等人；但如实报出来，结局不是本机这一答。
public struct RelayApprovalAnswering: ApprovalAnswering {
    private let connection: RelayConnection
    private let carrier: RelayCarrier

    public init(connection: RelayConnection, carrier: @escaping RelayCarrier = { $0.machineFingerprint }) {
        self.connection = connection
        self.carrier = carrier
    }

    @discardableResult
    public func submitToolPermission(_ reply: ToolPermissionReply) async throws -> ApprovalDelivery {
        var request = Agentre_Wire_RuntimeSubmitToolPermissionRequest()
        request.conversationID = reply.conversation.conversationID
        request.peerFingerprint = reply.peerFingerprint
        request.requestID = reply.requestID
        request.allow = reply.disposition.allow
        request.alwaysAllowSession = reply.disposition.alwaysAllowSession
        let response: Agentre_Wire_PeerSessionControlResponse = try await connection.call(
            machine: try await carrier(reply.conversation), .runtimeSubmitToolPermission, request
        )
        return response.alreadyHandled ? .alreadyHandled : .accepted
    }

    @discardableResult
    public func submitAnswer(_ reply: QuestionReply) async throws -> ApprovalDelivery {
        var request = Agentre_Wire_RuntimeSubmitAnswerRequest()
        request.conversationID = reply.conversation.conversationID
        request.peerFingerprint = reply.peerFingerprint
        request.requestID = reply.requestID
        request.questions = reply.questions.map { text in
            var question = Agentre_Wire_AskQuestion()
            question.question = text
            return question
        }
        request.answers = reply.answers.map { answer in
            var wire = Agentre_Wire_AskAnswer()
            wire.questionIndex = Int32(clamping: answer.questionIndex)
            wire.labels = answer.labels
            wire.otherText = answer.otherText
            return wire
        }
        request.skipped = reply.skipped
        let response: Agentre_Wire_PeerSessionControlResponse = try await connection.call(
            machine: try await carrier(reply.conversation), .runtimeSubmitAnswer, request
        )
        return response.alreadyHandled ? .alreadyHandled : .accepted
    }
}
