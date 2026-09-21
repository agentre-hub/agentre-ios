import AgentreDomain
import AgentreWire
import Foundation

/// 一档执行目标上的一条 Skill 授权（wire 的 SkillAuthorization）。授权存在组织数据里，
/// 应答的那台机器上没有，由调用方报进去。
public struct SkillGrant: Sendable, Equatable {
    public let id: String
    public let enabled: Bool

    public init(id: String, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }
}

/// 输入区的全部中继调用：经承载机的 `machine:` 通道、以 conversation_id 指明对话
/// （对照控制台 useSessionSend / useSteerAutoContinue / use-session-skill-commands）。
public struct RelayComposer: ComposerRelay {
    private let connection: RelayConnection
    private let source: RelaySourceDevice
    private let carrier: RelayCarrier
    private let conversation: @Sendable (ConversationKey) async -> SavedConversation?
    private let machineKind: @Sendable (String) async -> String?
    private let skillGrants: @Sendable (_ agentSyncID: String, _ backendType: String, _ machineFingerprint: String) async throws -> [SkillGrant]

    /// - Parameters:
    ///   - conversation: 会话摘要（本地库）：开新一轮要带上它的工作目录、标题、Agent 与后端。
    ///   - machineKind: 机器种类（desktop / agentred）；不知道时为 nil。
    ///   - skillGrants: 这一档的 Skill 授权（组织数据，REST）；取不到时按空授权问。
    public init(
        connection: RelayConnection,
        source: RelaySourceDevice,
        carrier: @escaping RelayCarrier = { $0.machineFingerprint },
        conversation: @escaping @Sendable (ConversationKey) async -> SavedConversation?,
        machineKind: @escaping @Sendable (String) async -> String?,
        skillGrants: @escaping @Sendable (String, String, String) async throws -> [SkillGrant]
    ) {
        self.connection = connection
        self.source = source
        self.carrier = carrier
        self.conversation = conversation
        self.machineKind = machineKind
        self.skillGrants = skillGrants
    }

    public func run(_ key: ConversationKey, peerFingerprint: String, text: String, compact: Bool, permissionMode: String) async throws {
        let summary = await conversation(key)
        var request = Agentre_Wire_RuntimeRunRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.cwd = summary?.cwd ?? ""
        request.title = summary?.title ?? ""
        request.agentSyncID = summary?.agentSyncID ?? ""
        var backend = Agentre_Wire_AgentBackend()
        backend.type = summary?.backendType ?? ""
        request.backend = backend
        // 压缩那一轮没有用户消息：把「/compact」也当正文送过去等于既压缩又多说一句。
        if compact {
            request.compact = true
        } else {
            request.userText = text
        }
        // 档位随每一轮过线（控制台 useSessionSend.ts 同此）：两轮之间执行端没有会话可改，只认这一格。
        request.permissionMode = permissionMode
        request.sourceDevice = source.fingerprint
        request.sourceDeviceName = source.name
        let _: Agentre_Wire_RuntimeRunResponse = try await connection.call(machine: await carrier(key), .runtimeRun, request)
    }

    /// 停下运行中的这一轮（对照控制台 SessionDetailHeader 的 abortTurn：带回发起端）。
    public func abort(_ key: ConversationKey, peerFingerprint: String) async throws {
        var request = Agentre_Wire_RuntimeAbortRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        let _: Agentre_Wire_RuntimeAbortResponse = try await connection.call(machine: await carrier(key), .runtimeAbort, request)
    }

    public func steer(_ key: ConversationKey, peerFingerprint: String, queuedID: String, text: String) async throws -> ComposerSteerHandle {
        var request = Agentre_Wire_RuntimeSteerRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.queuedID = queuedID
        request.text = text
        let response: Agentre_Wire_RuntimeSteerResponse = try await connection.call(machine: await carrier(key), .runtimeSteer, request)
        return ComposerSteerHandle(queuedID: response.queuedID, cancellable: response.cancellable)
    }

    public func cancelSteer(_ key: ConversationKey, peerFingerprint: String, queuedID: String) async throws -> [String] {
        var request = Agentre_Wire_RuntimeCancelSteerRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.queuedID = queuedID
        let response: Agentre_Wire_RuntimeCancelSteerResponse = try await connection.call(
            machine: await carrier(key), .runtimeCancelSteer, request
        )
        return response.removed
    }

    /// 只问 agentred：桌面端不注册这个方法，且它托管的会话由它自己在轮末取走并接续，去问就是抢。
    /// 种类还不知道时同样不问。
    public func drainPending(_ key: ConversationKey, peerFingerprint: String) async throws -> [ComposerConsumedSteer]? {
        let machine = await carrier(key)
        guard await machineKind(machine) == "agentred" else { return nil }
        var request = Agentre_Wire_RuntimeDrainPendingRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        let response: Agentre_Wire_RuntimeDrainPendingResponse = try await connection.call(machine: machine, .runtimeDrainPending, request)
        return response.steers.map { ComposerConsumedSteer(queuedID: $0.queuedID, text: $0.text) }
    }

    public func setPermissionMode(_ key: ConversationKey, peerFingerprint: String, mode: String) async throws {
        var request = Agentre_Wire_RuntimeSetPermissionModeRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.mode = mode
        let _: Agentre_Wire_Empty = try await connection.call(machine: await carrier(key), .runtimeSetPermissionMode, request)
    }

    public func setModelTarget(_ key: ConversationKey, peerFingerprint: String, providerKey: String, modelKey: String) async throws {
        var request = Agentre_Wire_SetModelTargetRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.providerKey = providerKey
        request.modelKey = modelKey
        let _: Agentre_Wire_SetModelTargetResponse = try await connection.call(machine: await carrier(key), .setModelTarget, request)
    }

    public func setReasoningEffort(_ key: ConversationKey, peerFingerprint: String, effort: String) async throws {
        var request = Agentre_Wire_SetSessionReasoningEffortRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.reasoningEffort = effort
        let _: Agentre_Wire_SetSessionReasoningEffortResponse = try await connection.call(
            machine: await carrier(key), .setSessionReasoningEffort, request
        )
    }

    public func deleteSession(_ key: ConversationKey, peerFingerprint: String) async throws -> Bool {
        var request = Agentre_Wire_SessionDeleteRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        let response: Agentre_Wire_SessionDeleteResponse = try await connection.call(machine: await carrier(key), .sessionDelete, request)
        return response.deleted
    }

    /// 问承载这条会话的机器。后端还不知道时不问：发一次注定答错的调用，代价是菜单里出现一批叫不动的名字。
    public func skillCommands(_ key: ConversationKey, agentSyncID: String, backendType: String, cwd: String) async throws -> [ComposerSkillSource] {
        guard !backendType.isEmpty else { return [] }
        let machineFingerprint = await carrier(key)
        // 授权拿不到不是不问的理由：机器仍答得出它自己解析的那一半。
        let grants = agentSyncID.isEmpty ? [] : ((try? await skillGrants(agentSyncID, backendType, machineFingerprint)) ?? [])
        var request = Agentre_Wire_SkillCommandsRequest()
        request.backendType = backendType
        request.cwd = cwd
        request.authorized = grants.map { grant in
            var authorization = Agentre_Wire_SkillAuthorization()
            authorization.id = grant.id
            authorization.enabled = grant.enabled
            return authorization
        }
        let response: Agentre_Wire_SkillCommandsResponse = try await connection.call(machine: machineFingerprint, .skillsCommands, request)
        return response.commands.map { ComposerSkillSource(name: $0.name, description: $0.description_p) }
    }
}

extension RelayComposer {
    /// 转录里执行端最后一次报的当前权限档位（permission_mode_changed，空档不算）；没报过为 nil。
    /// 与控制台 reduceSessionState 的 permissionMode 同一取法。
    public static func reportedPermissionMode(in frames: [TranscriptFrame]) -> String? {
        frames.reversed().lazy.compactMap { frame -> String? in
            guard let notification = try? Agentre_Wire_RpcNotification(serializedBytes: frame.payload) else { return nil }
            switch notification.payload {
            case .runtimeEvent(let event), .autonomousTurnEvent(let event):
                guard case .permissionModeChanged(let changed) = event.event, !changed.mode.isEmpty else { return nil }
                return changed.mode
            default:
                return nil
            }
        }.first
    }
}
