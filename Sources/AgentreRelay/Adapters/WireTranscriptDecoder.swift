import AgentreDomain
import AgentreWire
import Foundation

/// 一帧 wire 通知（`RpcNotification` 的 protobuf 字节）→ 转录事件。本地库存的与实时到达的是同一种字节，
/// 同一个解码器。不属于转录的通知（终端、端口转发）与坏字节解不出，交回 nil。
public struct WireTranscriptDecoder: TranscriptPayloadDecoding {
    public init() {}

    public func decode(_ payload: Data) -> DecodedNotification? {
        guard let notification = try? Agentre_Wire_RpcNotification(serializedBytes: payload) else { return nil }
        switch notification.payload {
        case .runtimeEvent(let event), .autonomousTurnEvent(let event):
            return DecodedNotification(preview: event.preview, event: Self.event(event.event))
        case .runResultDone(let done), .autonomousTurnDone(let done):
            return DecodedNotification(event: .turnDone(TurnDone(
                durationMs: Int(done.durationMs), contextWindow: Int(done.contextWindow), stopError: done.stopErrorMessage
            )))
        case .turnStarted, .autonomousTurnStarted:
            return DecodedNotification(event: .turnStarted)
        default:
            return nil
        }
    }

    private static func event(_ event: Agentre_Wire_RuntimeEventNotification.OneOf_Event?) -> TranscriptEvent {
        switch event {
        case .textDelta(let delta): .textDelta(delta.text)
        case .thinkingDelta(let delta): .thinkingDelta(delta.text)
        case .userMessage(let message): .userMessage(message.text)
        case .steerConsumed(let consumed): .steerConsumed(consumed.steers.map(\.text))
        case .toolCall(let call):
            .toolCall(ToolUse(
                id: call.id, name: call.name, input: object(call.input),
                canonical: Canonical(flat: JSONValue(json: call.canonical)), parentID: nonEmpty(call.parentToolCallID)
            ))
        case .toolResult(let result):
            .toolResult(ToolResult(
                toolCallID: result.toolCallID, text: result.content, isError: result.isError, parentID: nonEmpty(result.parentToolCallID)
            ))
        case .toolPermissionRequest(let request):
            .permissionRequest(PermissionRequest(
                requestID: request.requestID, toolCallID: request.toolCallID, toolName: request.toolName, input: object(request.input)
            ))
        case .toolPermissionResolved(let resolved): .permissionResolved(requestID: resolved.requestID, allowed: resolved.allowed)
        case .userAskRequest(let ask):
            .questionRequest(QuestionRequest(requestID: ask.requestID, toolCallID: ask.toolCallID, questions: ask.questions.map(question)))
        case .userAskResolved(let resolved): .questionResolved(requestID: resolved.requestID)
        case .subagentStarted(let update): .subagent(subagent(update, .started))
        case .subagentProgress(let update): .subagent(subagent(update, .progress))
        case .subagentDone(let update): .subagent(subagent(update, .done))
        case .usageUpdate(let usage): .usage(totalInputTokens: Int(usage.totalInputTokens), contextWindow: Int(usage.contextWindow))
        case .contextWindowUpdated(let window): .contextWindow(Int(window.tokens))
        case .done(let done): .turnDone(TurnDone(durationMs: Int(done.durationMs)))
        case .error(let error): .error(error.message)
        default: .ignored
        }
    }

    private static func object(_ data: Data) -> [String: JSONValue]? {
        JSONValue(json: data)?.object
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func question(_ question: Agentre_Wire_AskQuestion) -> AskQuestion {
        AskQuestion(
            id: question.id, question: question.question, header: question.header, multiSelect: question.multiSelect,
            isSecret: question.isSecret,
            options: question.options.map { AskOption(label: $0.label, description: $0.description_p) }
        )
    }

    private static func subagent(_ update: Agentre_Wire_SubagentEvent, _ phase: SubagentUpdate.Phase) -> SubagentUpdate {
        let info = update.info
        return SubagentUpdate(toolCallID: update.toolCallID, phase: phase, info: SubagentState(
            taskID: info.taskID, status: info.status, subagentType: info.subagentType, taskDescription: info.taskDescription,
            durationMs: Int(info.durationMs), toolUses: Int(info.toolUses)
        ))
    }
}
