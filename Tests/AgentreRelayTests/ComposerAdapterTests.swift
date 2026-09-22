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
        async let sent: Void = composer(harness).run(key, peerFingerprint: "peer-1", text: "go on", compact: false, permissionMode: "plan")
        let body = try await answer(harness, .runtimeRun, as: Agentre_Wire_RuntimeRunRequest.self, with: Agentre_Wire_RuntimeRunResponse())
        try await sent
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

    @Test("压缩：compact 为真且不带正文")
    func runCompacts() async throws {
        let harness = await Harness.started()
        async let sent: Void = composer(harness).run(key, peerFingerprint: "peer-1", text: "/compact", compact: true, permissionMode: "")
        let body = try await answer(harness, .runtimeRun, as: Agentre_Wire_RuntimeRunRequest.self, with: Agentre_Wire_RuntimeRunResponse())
        try await sent
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

    @Test("取回：承载机是 agentred 时问 runtimeDrainPending，交回取走的几条")
    func drainsOnAgentred() async throws {
        let harness = await Harness.started()
        async let drained = composer(harness).drainPending(key, peerFingerprint: "peer-1")
        var response = Agentre_Wire_RuntimeDrainPendingResponse()
        response.steers = [Agentre_Wire_ConsumedSteer.with { $0.queuedID = "host-7"; $0.text = "later" }]
        let body = try await answer(harness, .runtimeDrainPending, as: Agentre_Wire_RuntimeDrainPendingRequest.self, with: response)
        #expect(try await drained == [ComposerConsumedSteer(queuedID: "host-7", text: "later")])
        #expect(body.conversationID == "conv-1")
        #expect(body.peerFingerprint == "peer-1")
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
            (.runtimeRun, { try await $0.run(key, peerFingerprint: "", text: "x", compact: false, permissionMode: "") }),
            (.runtimeAbort, { try await $0.abort(key, peerFingerprint: "") }),
            (.runtimeSteer, { _ = try await $0.steer(key, peerFingerprint: "", queuedID: "q", text: "x") }),
            (.runtimeCancelSteer, { _ = try await $0.cancelSteer(key, peerFingerprint: "", queuedID: "q") }),
            (.runtimeDrainPending, { _ = try await $0.drainPending(key, peerFingerprint: "") }),
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
