import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

private let key = ConversationKey(machineFingerprint: "origin-fp", conversationID: "conv-1")
private let phone = RelaySourceDevice(fingerprint: "phone-fp", name: "My iPhone")
private let saved = SavedConversation(
    key: key, peerFingerprint: "peer-1", title: "Fix login", agentSyncID: "agent-1", cwd: "/repo", backendType: "claudecode"
)

private func composer(
    _ harness: Harness,
    kind: String? = "agentred",
    saved: SavedConversation = saved,
    grants: @escaping @Sendable (String, String, String) async throws -> [SkillGrant] = { _, _, _ in [] }
) -> RelayComposer {
    RelayComposer(
        connection: harness.connection, source: phone,
        carrier: { _ in "carrier-fp" },
        conversation: { $0 == key ? saved : nil },
        machineKind: { $0 == "carrier-fp" ? kind : nil },
        skillGrants: grants
    )
}

/// 在承载机通道上等 `method` 的请求，交回解出的请求体，并以 `response` 应答。
private func answer<Request: SwiftProtobuf.Message>(
    _ harness: Harness, _ method: Agentre_Wire_RpcMethod, as type: Request.Type,
    with response: some SwiftProtobuf.Message, on channel: (FakeSocket, String)? = nil
) async throws -> Request {
    let (socket, id) = if let channel { channel } else { try await harness.machineChannel("carrier-fp") }
    let frame = try await socket.nextRequest(on: id, method: method)
    socket.respond(id, to: frame, with: response)
    return try frame.body(Request.self)
}

@Suite struct ComposerAdapterTests {
    @Test("发送：runtimeRun 带 conversation_id、发起端、会话的工作目录 / 标题 / Agent / 后端、本机当前的权限档位与来源设备")
    func runSendsTurn() async throws {
        let harness = await Harness.started()
        async let sent = composer(harness).run(key, peerFingerprint: "peer-1", text: "go on", compact: false, permissionMode: "plan")
        let body = try await answer(harness, .runtimeRun, as: Agentre_Wire_RuntimeRunRequest.self, with: Agentre_Wire_RuntimeRunResponse())
        #expect(try await sent == .acknowledged)
        #expect(body.conversationID == "conv-1")
        #expect(body.peerFingerprint == "peer-1")
        #expect(body.userText == "go on")
        #expect(!body.compact)
        #expect(body.cwd == "/repo")
        #expect(body.title == "Fix login")
        #expect(body.agentSyncID == "agent-1")
        #expect(body.backend.type == "claudecode")
        #expect(body.permissionMode == "plan")
        #expect(body.sourceDevice == "phone-fp")
        #expect(body.sourceDeviceName == "My iPhone")
    }

    /// 开新一轮的应答到期未到：交回适配器接着发的那一次补拉请求。
    private func runTimesOut(_ harness: Harness, text: String, saved: SavedConversation = saved) async throws
        -> (Task<ComposerRunReceipt, any Error>, FakeSocket, String, Agentre_Wire_RpcFrame) {
        let composer = composer(harness, saved: saved)
        let sending = Task { try await composer.run(key, peerFingerprint: "peer-1", text: text, compact: false, permissionMode: "") }
        let (socket, id) = try await harness.machineChannel("carrier-fp")
        let run = try await socket.nextRequest(on: id, method: .runtimeRun)
        try await FailureScenario.timeout.apply(harness, socket, id, run)
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        return (sending, socket, id, pull)
    }

    private func pulled(_ frames: [(seq: Int64, text: String, source: String)]) -> Agentre_Wire_SessionPullResponse {
        var response = Agentre_Wire_SessionPullResponse()
        response.notifications = frames.map { frame in
            var event = Agentre_Wire_RuntimeEventNotification()
            event.conversationID = "conv-1"
            event.seq = frame.seq
            event.userMessage = .with {
                $0.text = frame.text
                $0.sourceDevice = frame.source
            }
            var durable = Agentre_Wire_DurableNotification()
            durable.seq = frame.seq
            durable.payload = .with { $0.runtimeEvent = event }
            return durable
        }
        response.cursor = frames.last?.seq ?? 0
        return response
    }

    @Test("开新一轮的应答没到、机器上发送前的帧号之后有本机发出的这句话：机器受理了，交回它此刻报的生命周期")
    func runAnswerLostButAccepted() async throws {
        let harness = await Harness.started()
        var known = saved
        known.latestSeq = 7
        let (sending, socket, id, pull) = try await runTimesOut(harness, text: "write kotlin", saved: known)
        let pullBody = try pull.body(Agentre_Wire_SessionPullRequest.self)
        #expect(pullBody.conversationID == "conv-1")
        #expect(pullBody.peerFingerprint == "peer-1")
        #expect(pullBody.cursor == 7)
        socket.respond(id, to: pull, with: pulled([(8, "write kotlin", "phone-fp")]))
        var summary = Agentre_Wire_SessionSummary()
        summary.conversationID = "conv-1"
        summary.lifecycleState = "running"
        var list = Agentre_Wire_SessionListResponse()
        list.sessions = [summary]
        let listed = try await answer(harness, .sessionList, as: Agentre_Wire_SessionListRequest.self, with: list, on: (socket, id))
        #expect(listed.conversationIds == ["conv-1"])
        #expect(try await sending.value == .confirmed(lifecycle: "running"))
    }

    @Test("开新一轮的应答没到、机器上没有本机发出的这句话（别处发的同一句不算）：照原样以到期收场", arguments: [
        [(Int64(8), "write kotlin", "desk-fp")], [(Int64(8), "something else", "phone-fp")], [],
    ])
    func runAnswerLostAndNotAccepted(_ frames: [(Int64, String, String)]) async throws {
        let harness = await Harness.started()
        let (sending, socket, id, pull) = try await runTimesOut(harness, text: "write kotlin")
        socket.respond(id, to: pull, with: pulled(frames.map { (seq: $0.0, text: $0.1, source: $0.2) }))
        await #expect(throws: RelayFailure.timedOut) { try await sending.value }
    }

    @Test("开新一轮被机器拒了：不回头问，照原样以拒绝收场")
    func runRefusedIsNotRechecked() async throws {
        let harness = await Harness.started()
        let composer = composer(harness)
        let sending = Task { try await composer.run(key, peerFingerprint: "peer-1", text: "write kotlin", compact: false, permissionMode: "") }
        let (socket, id) = try await harness.machineChannel("carrier-fp")
        let run = try await socket.nextRequest(on: id, method: .runtimeRun)
        try await FailureScenario.peerError.apply(harness, socket, id, run)
        await #expect(throws: RelayFailure.refused) { try await sending.value }
        #expect(socket.requests(on: id, method: .sessionPull).isEmpty)
    }

    @Test("压缩：compact 为真且不带正文")
    func runCompacts() async throws {
        let harness = await Harness.started()
        async let sent = composer(harness).run(key, peerFingerprint: "peer-1", text: "/compact", compact: true, permissionMode: "")
        let body = try await answer(harness, .runtimeRun, as: Agentre_Wire_RuntimeRunRequest.self, with: Agentre_Wire_RuntimeRunResponse())
        _ = try await sent
        #expect(body.compact)
        #expect(body.userText.isEmpty)
        #expect(body.permissionMode.isEmpty)
    }

    @Test("插话：runtimeSteer 带本端句柄与正文，交回执行端的句柄")
    func steers() async throws {
        let harness = await Harness.started()
        async let handle = composer(harness).steer(key, peerFingerprint: "peer-1", queuedID: "local-1", text: "also this")
        var response = Agentre_Wire_RuntimeSteerResponse()
        response.queuedID = "host-7"
        response.cancellable = true
        let body = try await answer(harness, .runtimeSteer, as: Agentre_Wire_RuntimeSteerRequest.self, with: response)
        #expect(try await handle == ComposerSteerHandle(queuedID: "host-7", cancellable: true))
        #expect(body.conversationID == "conv-1")
        #expect(body.peerFingerprint == "peer-1")
        #expect(body.queuedID == "local-1")
        #expect(body.text == "also this")
    }

    @Test("撤回：runtimeCancelSteer 交回确实撤掉的句柄")
    func cancelsSteer() async throws {
        let harness = await Harness.started()
        async let removed = composer(harness).cancelSteer(key, peerFingerprint: "peer-1", queuedID: "host-7")
        var response = Agentre_Wire_RuntimeCancelSteerResponse()
        response.removed = ["host-7"]
        let body = try await answer(harness, .runtimeCancelSteer, as: Agentre_Wire_RuntimeCancelSteerRequest.self, with: response)
        #expect(try await removed == ["host-7"])
        #expect(body.conversationID == "conv-1")
        #expect(body.queuedID == "host-7")
    }

    @Test("取回：承载机是 agentred 时先 attach 认下会话（它在轮末已从会话表里摘掉），应答之后才问 runtimeDrainPending，交回取走的几条")
    func drainsOnAgentred() async throws {
        let harness = await Harness.started()
        async let drained = composer(harness).drainPending(key, peerFingerprint: "peer-1")
        let (socket, id) = try await harness.machineChannel("carrier-fp")
        let attach = try await socket.nextRequest(on: id, method: .sessionAttach)
        try await Task.sleep(for: .milliseconds(100))
        #expect(socket.requests(on: id, method: .runtimeDrainPending).isEmpty, "drain asked before the attach was answered")
        socket.respond(id, to: attach, with: Agentre_Wire_SessionAttachResponse())
        let attachBody = try attach.body(Agentre_Wire_SessionAttachRequest.self)
        #expect(attachBody.conversationID == "conv-1")
        #expect(attachBody.peerFingerprint == "peer-1")
        var response = Agentre_Wire_RuntimeDrainPendingResponse()
        response.steers = [Agentre_Wire_ConsumedSteer.with { $0.queuedID = "host-7"; $0.text = "later" }]
        let body = try await answer(
            harness, .runtimeDrainPending, as: Agentre_Wire_RuntimeDrainPendingRequest.self, with: response, on: (socket, id)
        )
        #expect(try await drained == [ComposerConsumedSteer(queuedID: "host-7", text: "later")])
        #expect(body.conversationID == "conv-1")
        #expect(body.peerFingerprint == "peer-1")
    }

    @Test("取回：attach 被拒（这条会话的那一轮随上一个 agentred 进程消亡了）时照实报错，不再问信箱")
    func drainFailsWhenAttachRejected() async throws {
        let harness = await Harness.started()
        let adapter = composer(harness)
        let drained = Task { try await adapter.drainPending(key, peerFingerprint: "peer-1") }
        let (socket, id) = try await harness.machineChannel("carrier-fp")
        let attach = try await socket.nextRequest(on: id, method: .sessionAttach)
        socket.fail(id, to: attach, code: -32010, message: "agentruntime: no active turn for session")
        await #expect(throws: (any Error).self) { try await drained.value }
        #expect(socket.requests(on: id, method: .runtimeDrainPending).isEmpty)
    }

    @Test("取回：承载机是桌面端或种类还不知道时不问（桌面端自己在轮末接续），交回 nil", arguments: ["desktop", nil] as [String?])
    func drainSkipsNonAgentred(_ kind: String?) async throws {
        let harness = await Harness.started()
        let drained = try await composer(harness, kind: kind).drainPending(key, peerFingerprint: "peer-1")
        #expect(drained == nil)
        #expect(harness.dialer.sockets.allSatisfy { $0.frames.isEmpty })
    }

    @Test("权限档位、模型、思考档位（空串也要写下去）逐格带上")
    func changesSettings() async throws {
        let harness = await Harness.started()
        let adapter = composer(harness)

        async let mode: Void = adapter.setPermissionMode(key, peerFingerprint: "peer-1", mode: "acceptEdits")
        let channel = try await harness.machineChannel("carrier-fp")
        let modeBody = try await answer(
            harness, .runtimeSetPermissionMode, as: Agentre_Wire_RuntimeSetPermissionModeRequest.self, with: Agentre_Wire_Empty(), on: channel
        )
        try await mode
        #expect(modeBody.conversationID == "conv-1")
        #expect(modeBody.peerFingerprint == "peer-1")
        #expect(modeBody.mode == "acceptEdits")

        async let model: Void = adapter.setModelTarget(key, peerFingerprint: "peer-1", providerKey: "anthropic", modelKey: "opus")
        let modelBody = try await answer(harness, .setModelTarget, as: Agentre_Wire_SetModelTargetRequest.self, with: Agentre_Wire_SetModelTargetResponse(), on: channel)
        try await model
        #expect(modelBody.conversationID == "conv-1")
        #expect(modelBody.providerKey == "anthropic")
        #expect(modelBody.modelKey == "opus")

        async let effort: Void = adapter.setReasoningEffort(key, peerFingerprint: "peer-1", effort: "")
        let effortBody = try await answer(
            harness, .setSessionReasoningEffort, as: Agentre_Wire_SetSessionReasoningEffortRequest.self,
            with: Agentre_Wire_SetSessionReasoningEffortResponse(), on: channel
        )
        try await effort
        #expect(effortBody.conversationID == "conv-1")
        #expect(effortBody.reasoningEffort.isEmpty)
    }

    @Test("删除会话：sessionDelete 交回机器是否确实删了")
    func deletesSession() async throws {
        let harness = await Harness.started()
        async let deleted = composer(harness).deleteSession(key, peerFingerprint: "peer-1")
        var response = Agentre_Wire_SessionDeleteResponse()
        response.deleted = true
        let body = try await answer(harness, .sessionDelete, as: Agentre_Wire_SessionDeleteRequest.self, with: response)
        #expect(try await deleted)
        #expect(body.conversationID == "conv-1")
        #expect(body.peerFingerprint == "peer-1")
    }

    @Test("停止本轮：runtimeAbort 经承载机的通道，带 conversation_id 与发起端")
    func abortsTurn() async throws {
        let harness = await Harness.started()
        async let stopped: Void = composer(harness).abort(key, peerFingerprint: "peer-1")
        let body = try await answer(harness, .runtimeAbort, as: Agentre_Wire_RuntimeAbortRequest.self, with: Agentre_Wire_RuntimeAbortResponse())
        try await stopped
        #expect(body.conversationID == "conv-1")
        #expect(body.peerFingerprint == "peer-1")
    }

    @Test("斜杠命令：在承载机（不是会话键上的发起端）上问 skillsCommands，带后端、工作目录与这一档的授权")
    func asksSkillCommands() async throws {
        let harness = await Harness.started()
        let adapter = composer(harness, grants: { agent, backend, machine in
            agent == "agent-1" && backend == "claudecode" && machine == "carrier-fp" ? [SkillGrant(id: "pack-1", enabled: true)] : []
        })
        async let skills = adapter.skillCommands(key, agentSyncID: "agent-1", backendType: "claudecode", cwd: "/repo")
        var response = Agentre_Wire_SkillCommandsResponse()
        response.commands = [Agentre_Wire_SkillCommand.with { $0.name = "review"; $0.description_p = "Review code" }]
        let body = try await answer(harness, .skillsCommands, as: Agentre_Wire_SkillCommandsRequest.self, with: response)
        #expect(try await skills == [ComposerSkillSource(name: "review", description: "Review code")])
        #expect(body.backendType == "claudecode")
        #expect(body.cwd == "/repo")
        #expect(body.authorized.map(\.id) == ["pack-1"])
        #expect(body.authorized.map(\.enabled) == [true])
    }

    @Test("授权取不到不是不问的理由：按空授权照问")
    func skillCommandsWithoutGrants() async throws {
        let harness = await Harness.started()
        struct Unavailable: Error {}
        let adapter = composer(harness, grants: { _, _, _ in throw Unavailable() })
        async let skills = adapter.skillCommands(key, agentSyncID: "agent-1", backendType: "codex", cwd: "")
        let body = try await answer(harness, .skillsCommands, as: Agentre_Wire_SkillCommandsRequest.self, with: Agentre_Wire_SkillCommandsResponse())
        #expect(try await skills.isEmpty)
        #expect(body.authorized.isEmpty)
    }

    @Test("后端还不知道时不问，一条都不列")
    func skillCommandsNeedBackend() async throws {
        let harness = await Harness.started()
        let skills = try await composer(harness).skillCommands(key, agentSyncID: "agent-1", backendType: "", cwd: "/repo")
        #expect(skills.isEmpty)
        #expect(harness.dialer.sockets.allSatisfy { $0.frames.isEmpty })
    }

    @Test("每个调用的错误应答与到期无应答都以领域失败收场", arguments: FailureScenario.allCases)
    func failuresAreDomainFacts(_ scenario: FailureScenario) async throws {
        typealias Call = @Sendable (RelayComposer) async throws -> Void
        let calls: [(Agentre_Wire_RpcMethod, Call)] = [
            // 到期之后开新一轮还要回头问机器（见 runAnswerLost…）；这里只看压缩那一轮：它没有用户消息可认。
            (.runtimeRun, { _ = try await $0.run(key, peerFingerprint: "", text: "/compact", compact: true, permissionMode: "") }),
            (.runtimeAbort, { try await $0.abort(key, peerFingerprint: "") }),
            (.runtimeSteer, { _ = try await $0.steer(key, peerFingerprint: "", queuedID: "q", text: "x") }),
            (.runtimeCancelSteer, { _ = try await $0.cancelSteer(key, peerFingerprint: "", queuedID: "q") }),
            // 取回的第一问是 attach（见 drainsOnAgentred）：它失败就到此为止。
            (.sessionAttach, { _ = try await $0.drainPending(key, peerFingerprint: "") }),
            (.runtimeSetPermissionMode, { try await $0.setPermissionMode(key, peerFingerprint: "", mode: "plan") }),
            (.setModelTarget, { try await $0.setModelTarget(key, peerFingerprint: "", providerKey: "p", modelKey: "m") }),
            (.setSessionReasoningEffort, { try await $0.setReasoningEffort(key, peerFingerprint: "", effort: "high") }),
            (.sessionDelete, { _ = try await $0.deleteSession(key, peerFingerprint: "") }),
            (.skillsCommands, { _ = try await $0.skillCommands(key, agentSyncID: "a", backendType: "claudecode", cwd: "") }),
        ]
        for (method, call) in calls {
            let error = try await failure(scenario, method: method, on: "carrier-fp") { harness in
                try await call(composer(harness))
            }
            #expect(error as? RelayFailure == scenario.expected, "\(method)")
        }
    }
}
