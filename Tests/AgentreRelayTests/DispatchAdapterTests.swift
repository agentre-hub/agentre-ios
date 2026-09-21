import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

private let phone = RelaySourceDevice(fingerprint: "phone-fp", name: "My iPhone")

private func request(kind: String = "desktop", backendType: String = "claudecode", project: String? = "proj-1") -> DispatchRequest {
    DispatchRequest(
        conversationID: "0190-conv", title: "Fix login", userText: "Fix login\nplease", agentSyncID: "agent-1",
        projectSyncID: project,
        target: DispatchChoice(
            deviceFingerprint: "fp-9", deviceName: "Studio", backendSyncID: "be-1", backendType: backendType, kind: kind, cwd: "/repo"
        )
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
        #expect(body.permissionMode.isEmpty)
        #expect(!body.compact)
        socket.respond(id, to: run, with: ack("0190-conv"))
        try await sent
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

    @Test("对端拒绝 → rejected；到期无应答 → unreachable（连不上那台机器），都不带码与原串", arguments: FailureScenario.allCases)
    func failuresAreDispatchFailures(_ scenario: FailureScenario) async throws {
        let error = try await failure(scenario, method: .runtimeRun, on: "fp-9") { harness in
            try await RelayDispatcher(connection: harness.connection, source: phone).dispatch(request())
        }
        #expect(error as? DispatchFailure == (scenario == .peerError ? .rejected : .unreachable))
    }
}
