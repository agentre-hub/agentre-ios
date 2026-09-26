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

    /// 应答没到（到期、连接断了、通道被关）不等于机器没受理：agentred 先置 running、推开轮帧、落下用户那一帧，
    /// 然后才回应答（agentre/internal/daemon/handlers/runtime.go:571-593），这一轮也不随那次请求取消（:540-544）。
    /// 手机发出后进了后台被挂起时，应答连同开轮帧就丢在那条连接上（report-7 11f）。此时回头问机器：发送前本机
    /// 最新帧号之后有这句话，就是受理了。问不到或没有，才照原样抛出。
    public func run(_ key: ConversationKey, peerFingerprint: String, text: String, compact: Bool, permissionMode: String) async throws -> ComposerRunReceipt {
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
        let machine = try await carrier(key)
        do {
            let _: Agentre_Wire_RuntimeRunResponse = try await connection.call(machine: machine, .runtimeRun, request)
            return .acknowledged
        } catch let failure as RelayFailure where [.timedOut, .connectionLost, .machineUnreachable].contains(failure) && !compact {
            let after = summary?.latestSeq ?? 0
            guard let receipt = try? await accepted(key, peerFingerprint: peerFingerprint, on: machine, text: text, after: after) else {
                throw failure
            }
            return receipt
        }
    }

    /// 机器上这条会话在 `after` 之后有一条本机发出、正文就是 `text` 的用户消息：受理了，附机器此刻报的生命周期
    /// （认出之后生命周期没问到，受理仍是确定的：生命周期为 nil）；没有为 nil。
    /// 压缩那一轮没有用户消息可认，不走这里。
    private func accepted(
        _ key: ConversationKey, peerFingerprint: String, on machine: String, text: String, after: Int64
    ) async throws -> ComposerRunReceipt? {
        var cursor = after
        while true {
            var pull = Agentre_Wire_SessionPullRequest()
            pull.conversationID = key.conversationID
            pull.peerFingerprint = peerFingerprint
            pull.cursor = cursor
            pull.limit = RelayProtocol.pullLimit
            let page: Agentre_Wire_SessionPullResponse = try await connection.call(machine: machine, .sessionPull, pull)
            let sent = page.notifications.contains { notification in
                guard case .runtimeEvent(let event) = notification.payload.payload, case .userMessage(let message) = event.event else { return false }
                return message.sourceDevice == source.fingerprint && message.text == text
            }
            if sent {
                var list = Agentre_Wire_SessionListRequest()
                list.conversationIds = [key.conversationID]
                let sessions: Agentre_Wire_SessionListResponse? = try? await connection.call(machine: machine, .sessionList, list)
                return .confirmed(lifecycle: sessions?.sessions.first { $0.conversationID == key.conversationID }?.lifecycleState)
            }
            guard page.hasMore_p, page.cursor > cursor else { return nil }
            cursor = page.cursor
        }
    }

    /// 停下运行中的这一轮（对照控制台 SessionDetailHeader 的 abortTurn：带回发起端）。
    public func abort(_ key: ConversationKey, peerFingerprint: String) async throws {
        var request = Agentre_Wire_RuntimeAbortRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        let _: Agentre_Wire_RuntimeAbortResponse = try await connection.call(machine: try await carrier(key), .runtimeAbort, request)
    }

    public func steer(_ key: ConversationKey, peerFingerprint: String, queuedID: String, text: String) async throws -> ComposerSteerHandle {
        var request = Agentre_Wire_RuntimeSteerRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.queuedID = queuedID
        request.text = text
        let response: Agentre_Wire_RuntimeSteerResponse = try await connection.call(machine: try await carrier(key), .runtimeSteer, request)
        return ComposerSteerHandle(queuedID: response.queuedID, cancellable: response.cancellable)
    }

    public func cancelSteer(_ key: ConversationKey, peerFingerprint: String, queuedID: String) async throws -> [String] {
        var request = Agentre_Wire_RuntimeCancelSteerRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.queuedID = queuedID
        let response: Agentre_Wire_RuntimeCancelSteerResponse = try await connection.call(
            machine: try await carrier(key), .runtimeCancelSteer, request
        )
        return response.removed
    }

    /// 只问 agentred：桌面端不注册这个方法，且它托管的会话由它自己在轮末取走并接续，去问就是抢。
    /// 种类还不知道时同样不问。
    ///
    /// 先 attach 再问：agentred 在发出收场帧之前就把这一轮从这条连接的会话表里摘掉了，此后的控制 RPC 一律回
    /// 「没有进行中的一轮」（agentre/internal/daemon/handlers/runtime.go:940-941、:1682-1689）；attach 在表里放回一行
    /// 占位（AdoptForPeer，runtime.go:243-254），信箱才问得到（它按 CLI 会话存，跨轮仍在）。
    public func drainPending(_ key: ConversationKey, peerFingerprint: String) async throws -> [ComposerConsumedSteer]? {
        let machine = try await carrier(key)
        guard await machineKind(machine) == "agentred" else { return nil }
        var attach = Agentre_Wire_SessionAttachRequest()
        attach.conversationID = key.conversationID
        attach.peerFingerprint = peerFingerprint
        let _: Agentre_Wire_SessionAttachResponse = try await connection.call(machine: machine, .sessionAttach, attach)
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
        let _: Agentre_Wire_Empty = try await connection.call(machine: try await carrier(key), .runtimeSetPermissionMode, request)
    }

    public func setModelTarget(_ key: ConversationKey, peerFingerprint: String, providerKey: String, modelKey: String) async throws {
        var request = Agentre_Wire_SetModelTargetRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.providerKey = providerKey
        request.modelKey = modelKey
        let _: Agentre_Wire_SetModelTargetResponse = try await connection.call(machine: try await carrier(key), .setModelTarget, request)
    }

    public func setReasoningEffort(_ key: ConversationKey, peerFingerprint: String, effort: String) async throws {
        var request = Agentre_Wire_SetSessionReasoningEffortRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        request.reasoningEffort = effort
        let _: Agentre_Wire_SetSessionReasoningEffortResponse = try await connection.call(
            machine: try await carrier(key), .setSessionReasoningEffort, request
        )
    }

    public func deleteSession(_ key: ConversationKey, peerFingerprint: String) async throws -> Bool {
        var request = Agentre_Wire_SessionDeleteRequest()
        request.conversationID = key.conversationID
        request.peerFingerprint = peerFingerprint
        let response: Agentre_Wire_SessionDeleteResponse = try await connection.call(machine: try await carrier(key), .sessionDelete, request)
        return response.deleted
    }

    /// 问承载这条会话的机器。后端还不知道时不问：发一次注定答错的调用，代价是菜单里出现一批叫不动的名字。
    public func skillCommands(_ key: ConversationKey, agentSyncID: String, backendType: String, cwd: String) async throws -> [ComposerSkillSource] {
        guard !backendType.isEmpty else { return [] }
        let machineFingerprint = try await carrier(key)
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
