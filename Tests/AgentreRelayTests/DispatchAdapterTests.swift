import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

private let phone = RelaySourceDevice(fingerprint: "phone-fp", name: "My iPhone")

private func request(
    kind: String = "desktop", backendType: String = "claudecode", project: String? = "proj-1", settings: ComposerRunSettings = ComposerRunSettings()
) -> DispatchRequest {
    DispatchRequest(
        conversationID: "0190-conv", title: "Fix login", userText: "Fix login\nplease", agentSyncID: "agent-1",
        projectSyncID: project,
        target: DispatchChoice(
            deviceFingerprint: "fp-9", deviceName: "Studio", backendSyncID: "be-1", backendType: backendType, kind: kind, cwd: "/repo"
        ),
        settings: settings
    )
}

private let drafted = ComposerRunSettings(permissionMode: "plan", providerKey: "anthropic", modelKey: "opus", reasoningEffort: "high")

/// 应答派发收尾的两次钉住（模型目标、思考档位）。
private func answerPins(_ socket: FakeSocket, _ id: String) async throws {
    socket.respond(id, to: try await socket.nextRequest(on: id, method: .setModelTarget), with: Agentre_Wire_SetModelTargetResponse())
    socket.respond(
        id, to: try await socket.nextRequest(on: id, method: .setSessionReasoningEffort), with: Agentre_Wire_SetSessionReasoningEffortResponse()
    )
}

private func ack(_ conversationID: String, providerSession: String = "") -> Agentre_Wire_RuntimeRunResponse {
    var response = Agentre_Wire_RuntimeRunResponse()
    response.conversationID = conversationID
    response.providerSessionID = providerSession
    return response
}

@Suite struct DispatchAdapterTests {
    @Test("派发：在选中机器的 machine: 通道上发 runtimeRun，会话号、标题、正文、Agent、项目、工作目录、后端与来源设备逐格带上")
    func dispatchesRun() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        async let sent: Void = adapter.dispatch(request())
        let (socket, id) = try await harness.machineChannel("fp-9")
        let run = try await socket.nextRequest(on: id, method: .runtimeRun)
        let body = try run.body(Agentre_Wire_RuntimeRunRequest.self)
        #expect(body.conversationID == "0190-conv")
        #expect(body.title == "Fix login")
        #expect(body.userText == "Fix login\nplease")
        #expect(body.agentSyncID == "agent-1")
        #expect(body.projectSyncID == "proj-1")
        #expect(body.cwd == "/repo")
        #expect(body.agentID == 0)
        #expect(body.backend.type == "claudecode")
        // 桌面端不走配置快照通路，不带后端同步号。
        #expect(body.backend.syncID.isEmpty)
        #expect(body.sourceDevice == "phone-fp")
        #expect(body.sourceDeviceName == "My iPhone")
        // 草稿上一项都没选：三格留空，按 Agent 绑定与后端配置跑。
        #expect(body.permissionMode.isEmpty)
        #expect(body.llmProviderKey.isEmpty)
        #expect(body.llmModelKey.isEmpty)
        #expect(body.reasoningEffort.isEmpty)
        #expect(!body.compact)
        socket.respond(id, to: run, with: ack("0190-conv"))
        try await sent
        // 一项都没选：会话行不钉，模型与档位留给 Agent 绑定与后端配置。
        #expect(socket.requests(on: id, method: .setModelTarget).isEmpty)
        #expect(socket.requests(on: id, method: .setSessionReasoningEffort).isEmpty)
    }

    @Test("草稿上选的权限模式、模型、思考档位随第一条 runtime.run 带过去")
    func carriesDraftSettings() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        async let sent: Void = adapter.dispatch(request(kind: "agentred", settings: drafted))
        let (socket, id) = try await harness.machineChannel("fp-9")
        let run = try await socket.nextRequest(on: id, method: .runtimeRun)
        let body = try run.body(Agentre_Wire_RuntimeRunRequest.self)
        #expect(body.permissionMode == "plan")
        #expect(body.llmProviderKey == "anthropic")
        #expect(body.llmModelKey == "opus")
        #expect(body.reasoningEffort == "high")
        socket.respond(id, to: run, with: ack("0190-conv"))
        try await answerPins(socket, id)
        try await sent
    }

    @Test("草稿上选的模型与思考档位在 runtime.run 被接受后钉到这条会话上：run 带的只管第一轮，会话行只有这两个 RPC 写")
    func pinsDraftModelAndEffortAfterRun() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        async let sent: Void = adapter.dispatch(request(settings: drafted))
        let (socket, id) = try await harness.machineChannel("fp-9")
        let run = try await socket.nextRequest(on: id, method: .runtimeRun)
        // run 被接受之前不钉：那时会话还不存在，钉了只会回「会话不在」。
        #expect(socket.requests(on: id, method: .setModelTarget).isEmpty)
        socket.respond(id, to: run, with: ack("0190-conv"))

        let target = try await socket.nextRequest(on: id, method: .setModelTarget)
        let targetBody = try target.body(Agentre_Wire_SetModelTargetRequest.self)
        #expect(targetBody.conversationID == "0190-conv")
        #expect(targetBody.peerFingerprint == "phone-fp")
        #expect(targetBody.providerKey == "anthropic")
        #expect(targetBody.modelKey == "opus")
        socket.respond(id, to: target, with: Agentre_Wire_SetModelTargetResponse())

        let effort = try await socket.nextRequest(on: id, method: .setSessionReasoningEffort)
        let effortBody = try effort.body(Agentre_Wire_SetSessionReasoningEffortRequest.self)
        #expect(effortBody.conversationID == "0190-conv")
        #expect(effortBody.peerFingerprint == "phone-fp")
        #expect(effortBody.reasoningEffort == "high")
        socket.respond(id, to: effort, with: Agentre_Wire_SetSessionReasoningEffortResponse())
        try await sent
    }

    @Test("只选了思考档位：只钉档位；选了供应商没选模型：照钉，模型键空即该供应商的默认模型")
    func pinsOnlyWhatWasChosen() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        async let effortOnly: Void = adapter.dispatch(request(settings: ComposerRunSettings(reasoningEffort: "low")))
        let (socket, id) = try await harness.machineChannel("fp-9")
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .runtimeRun), with: ack("0190-conv"))
        let effort = try await socket.nextRequest(on: id, method: .setSessionReasoningEffort)
        #expect(try effort.body(Agentre_Wire_SetSessionReasoningEffortRequest.self).reasoningEffort == "low")
        socket.respond(id, to: effort, with: Agentre_Wire_SetSessionReasoningEffortResponse())
        try await effortOnly
        #expect(socket.requests(on: id, method: .setModelTarget).isEmpty)

        async let providerDefault: Void = adapter.dispatch(request(settings: ComposerRunSettings(providerKey: "anthropic")))
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .runtimeRun), with: ack("0190-conv"))
        let target = try await socket.nextRequest(on: id, method: .setModelTarget)
        let body = try target.body(Agentre_Wire_SetModelTargetRequest.self)
        #expect(body.providerKey == "anthropic")
        #expect(body.modelKey.isEmpty)
        socket.respond(id, to: target, with: Agentre_Wire_SetModelTargetResponse())
        try await providerDefault
        #expect(socket.requests(on: id, method: .setSessionReasoningEffort).count == 1)
    }

    @Test("钉不住不算派发失败：会话已经在机器上跑起来了，报成失败用户一重试就凭空再开一条")
    func failedPinStillDispatched() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        async let sent: Void = adapter.dispatch(request(settings: drafted))
        let (socket, id) = try await harness.machineChannel("fp-9")
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .runtimeRun), with: ack("0190-conv"))
        socket.fail(id, to: try await socket.nextRequest(on: id, method: .setModelTarget), code: -32002, message: "Session not found")
        socket.fail(id, to: try await socket.nextRequest(on: id, method: .setSessionReasoningEffort), code: -32002, message: "Session not found")
        try await sent
    }

    @Test("Pi：用户选的权限模式不上线（那一格承载归属令牌），模型与思考档位照带", arguments: ["agentred", "desktop"])
    func piOmitsUserPermissionMode(_ kind: String) async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        async let sent: Void = adapter.dispatch(request(kind: kind, backendType: "piagent", settings: drafted))
        let (socket, id) = try await harness.machineChannel("fp-9")
        // agentred 上的 Pi 分注册、准备、启动三步；桌面端只一步。
        var bodies: [Agentre_Wire_RuntimeRunRequest] = []
        for step in 0..<(kind == "agentred" ? 3 : 1) {
            let run = try await socket.nextRequest(on: id, method: .runtimeRun)
            bodies.append(try run.body(Agentre_Wire_RuntimeRunRequest.self))
            socket.respond(id, to: run, with: ack("0190-conv", providerSession: step == 0 ? "" : "pi-sess-1"))
        }
        try await answerPins(socket, id)
        try await sent
        for body in bodies {
            #expect(body.permissionMode != "plan")
            #expect(body.llmProviderKey == "anthropic")
            #expect(body.llmModelKey == "opus")
            #expect(body.reasoningEffort == "high")
        }
    }

    @Test("agentred 上的派发带后端同步号，daemon 据它取整份配置；不指定项目时 project_sync_id 为空")
    func agentredCarriesBackendSyncID() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        async let sent: Void = adapter.dispatch(request(kind: "agentred", project: nil))
        let (socket, id) = try await harness.machineChannel("fp-9")
        let run = try await socket.nextRequest(on: id, method: .runtimeRun)
        let body = try run.body(Agentre_Wire_RuntimeRunRequest.self)
        #expect(body.backend.syncID == "be-1")
        #expect(body.projectSyncID.isEmpty)
        socket.respond(id, to: run, with: ack("0190-conv"))
        try await sent
    }

    @Test("agentred 上的 Pi：同一 generation 令牌依次注册、准备、启动，启动带上准备交回的会话号")
    func piGenerationThreeSteps() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        async let sent: Void = adapter.dispatch(request(kind: "agentred", backendType: "piagent"))
        let (socket, id) = try await harness.machineChannel("fp-9")

        let register = try await socket.nextRequest(on: id, method: .runtimeRun)
        let token = try register.body(Agentre_Wire_RuntimeRunRequest.self).permissionMode
        #expect(token.hasPrefix("mobile-pi-generation-"))
        socket.respond(id, to: register, with: ack("0190-conv"))

        let prepare = try await socket.nextRequest(on: id, method: .runtimeRun)
        #expect(try prepare.body(Agentre_Wire_RuntimeRunRequest.self).permissionMode == token)
        #expect(try prepare.body(Agentre_Wire_RuntimeRunRequest.self).providerSessionID.isEmpty)
        socket.respond(id, to: prepare, with: ack("0190-conv", providerSession: "pi-sess-1"))

        let start = try await socket.nextRequest(on: id, method: .runtimeRun)
        let startBody = try start.body(Agentre_Wire_RuntimeRunRequest.self)
        #expect(startBody.permissionMode == token)
        #expect(startBody.providerSessionID == "pi-sess-1")
        socket.respond(id, to: start, with: ack("0190-conv", providerSession: "pi-sess-1"))
        try await sent
        #expect(socket.requests(on: id, method: .runtimeAbort).isEmpty)
    }

    @Test("Pi 准备没交回会话号：判为没开起来，并撤掉这条会话")
    func piWithoutProviderSessionAborts() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        let task = Task { try await adapter.dispatch(request(kind: "agentred", backendType: "piagent")) }
        let (socket, id) = try await harness.machineChannel("fp-9")
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .runtimeRun), with: ack("0190-conv"))
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .runtimeRun), with: ack("0190-conv"))
        let abort = try await socket.nextRequest(on: id, method: .runtimeAbort)
        #expect(try abort.body(Agentre_Wire_RuntimeAbortRequest.self).conversationID == "0190-conv")
        socket.respond(id, to: abort, with: Agentre_Wire_RuntimeAbortResponse())
        await #expect(throws: DispatchFailure.rejected) { try await task.value }
    }

    @Test("Pi 派发中途被取消（离开了新建对话屏）：照样撤掉这条会话，不留一个注册了一半的 generation")
    func cancelledPiDispatchStillAborts() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        let task = Task { try await adapter.dispatch(request(kind: "agentred", backendType: "piagent")) }
        let (socket, id) = try await harness.machineChannel("fp-9")
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .runtimeRun), with: ack("0190-conv"))
        _ = try await socket.nextRequest(on: id, method: .runtimeRun)
        task.cancel()
        let abort = try await socket.nextRequest(on: id, method: .runtimeAbort)
        #expect(try abort.body(Agentre_Wire_RuntimeAbortRequest.self).conversationID == "0190-conv")
        socket.respond(id, to: abort, with: Agentre_Wire_RuntimeAbortResponse())
        _ = await task.result
    }

    @Test("对端确认的是另一条会话：判为没开起来")
    func mismatchedAckIsRejected() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        let task = Task { try await adapter.dispatch(request()) }
        let (socket, id) = try await harness.machineChannel("fp-9")
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .runtimeRun), with: ack("someone-else"))
        await #expect(throws: DispatchFailure.rejected) { try await task.value }
    }

    @Test("那台机器的协议版本与本 App 不等：派发失败读作要更新 App，而不是连不上那台机器")
    func versionMismatchNeedsAnUpdate() async throws {
        let harness = await Harness.started()
        let adapter = RelayDispatcher(connection: harness.connection, source: phone)
        let task = Task { try await adapter.dispatch(request()) }
        let socket = try await harness.dialer.socket(0)
        let id = try await socket.channelID(for: .machine(fingerprint: "fp-9"))
        let auth = try await socket.nextRequest(on: id, method: .authAccount)
        socket.fail(id, to: auth, code: RelayProtocol.errorCodeProtocolVersion, message: "protocol version 0.3.0 not supported")
        guard case .failure(let error) = await task.result else {
            Issue.record("dispatch succeeded")
            return
        }
        #expect(error is DispatchFailure)
        #expect(String(describing: error) == "updateRequired")
    }

    @Test("对端拒绝 → rejected；到期无应答 → unreachable（连不上那台机器），都不带码与原串", arguments: FailureScenario.allCases)
    func failuresAreDispatchFailures(_ scenario: FailureScenario) async throws {
        let error = try await failure(scenario, method: .runtimeRun, on: "fp-9") { harness in
            try await RelayDispatcher(connection: harness.connection, source: phone).dispatch(request())
        }
        #expect(error as? DispatchFailure == (scenario == .peerError ? .rejected : .unreachable))
    }
}
