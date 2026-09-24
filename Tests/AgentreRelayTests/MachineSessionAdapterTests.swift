import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

private func summary(_ id: String, peer: String = "", latest: Int64 = 0) -> Agentre_Wire_SessionSummary {
    var summary = Agentre_Wire_SessionSummary()
    summary.conversationID = id
    summary.peerFingerprint = peer
    summary.title = "Fix login"
    summary.agentSyncID = "agent-1"
    summary.cwd = "/repo"
    summary.projectSyncID = "proj-1"
    summary.backendType = "claudecode"
    summary.lifecycleState = "running"
    summary.waitingForInput = true
    summary.latestSeq = latest
    summary.lastMessageAt = 1_700_000_000_000
    summary.providerKey = "anthropic"
    summary.modelKey = "claude-sonnet"
    summary.reasoningEffort = "high"
    return summary
}

private func durableFrame(_ seq: Int64, createtime: Int64) -> Agentre_Wire_DurableNotification {
    var frame = Agentre_Wire_DurableNotification()
    frame.seq = seq
    frame.payload = relayTurnStarted("conv-1", seq: seq)
    frame.createtime = createtime
    return frame
}

@Suite struct MachineSessionAdapterTests {
    @Test("会话清单：machine:<指纹> 上发 sessionList（关键词 / 游标 / 条数），应答逐格映射成领域页")
    func listsSessions() async throws {
        let harness = await Harness.started()
        let adapter = RelayMachineSessions(connection: harness.connection, caller: "phone-fp")
        async let page = adapter.sessions(on: "fp-1", keyword: "login", cursor: "c-2", limit: 20)

        let (socket, id) = try await harness.machineChannel("fp-1")
        let request = try await socket.nextRequest(on: id, method: .sessionList)
        let body = try request.body(Agentre_Wire_SessionListRequest.self)
        #expect(body.keyword == "login")
        #expect(body.cursor == "c-2")
        #expect(body.limit == 20)
        #expect(body.conversationIds.isEmpty)

        var response = Agentre_Wire_SessionListResponse()
        response.sessions = [summary("conv-1", peer: "peer-1", latest: 42), summary("conv-2")]
        response.cursor = "c-3"
        response.hasMore_p = true
        socket.respond(id, to: request, with: response)

        let result = try await page
        #expect(result.cursor == "c-3")
        #expect(result.hasMore)
        #expect(result.sessions.map(\.conversationID) == ["conv-1", "conv-2"])
        #expect(result.sessions[0] == MachineSession(
            conversationID: "conv-1", peerFingerprint: "peer-1", title: "Fix login", agentSyncID: "agent-1", cwd: "/repo",
            projectSyncID: "proj-1", backendType: "claudecode", lifecycleState: "running", waitingForInput: true,
            latestSeq: 42, lastMessageAt: 1_700_000_000_000,
            providerKey: "anthropic", modelKey: "claude-sonnet", reasoningEffort: "high"
        ))
    }

    @Test("清单里的发起端：agentred 对调用方自己发起的那行不回显（空），交回的是本机指纹；他端与机器自己的原样")
    func listNamesTheCallerAsOriginOfItsOwnSessions() async throws {
        let harness = await Harness.started()
        let adapter = RelayMachineSessions(connection: harness.connection, caller: "phone-fp")
        async let page = adapter.sessions(on: "fp-1", keyword: "", cursor: "", limit: 20)
        let (socket, id) = try await harness.machineChannel("fp-1")
        let request = try await socket.nextRequest(on: id, method: .sessionList)
        var response = Agentre_Wire_SessionListResponse()
        response.sessions = [summary("mine", peer: ""), summary("desk", peer: "desktop-fp"), summary("host", peer: "fp-1")]
        socket.respond(id, to: request, with: response)

        let origins = try await page.sessions.map(\.peerFingerprint)
        #expect(origins == ["phone-fp", "desktop-fp", "fp-1"])
    }

    @Test("计数：sessionCounts 的三个数原样交出")
    func countsSessions() async throws {
        let harness = await Harness.started()
        let adapter = RelayMachineSessions(connection: harness.connection, caller: "phone-fp")
        async let counts = adapter.counts(on: "fp-1")
        let (socket, id) = try await harness.machineChannel("fp-1")
        let request = try await socket.nextRequest(on: id, method: .sessionCounts)
        var response = Agentre_Wire_SessionCountsResponse()
        response.total = 9
        response.running = 2
        response.waiting = 1
        socket.respond(id, to: request, with: response)
        #expect(try await counts == MachineSessionCounts(total: 9, running: 2, waiting: 1))
    }

    /// 点名问一条会话：以 conversation_ids 收窄，应答里的那几行按键挑出这一条。
    private func lookUp(_ key: ConversationKey, answering rows: [Agentre_Wire_SessionSummary]) async throws -> MachineSession? {
        let harness = await Harness.started()
        let adapter = RelayMachineSessions(connection: harness.connection, caller: "phone-fp")
        async let found = adapter.session(key, on: "fp-1")
        let (socket, id) = try await harness.machineChannel("fp-1")
        let request = try await socket.nextRequest(on: id, method: .sessionList)
        #expect(try request.body(Agentre_Wire_SessionListRequest.self).conversationIds == [key.conversationID])
        var response = Agentre_Wire_SessionListResponse()
        response.sessions = rows
        socket.respond(id, to: request, with: response)
        return try await found
    }

    @Test("点名问手机自己发起的会话：agentred 对调用方自己发起的那行不回显发起端（空），本机的键仍认得它，交回的发起端是本机")
    func looksUpCallerOriginatedSession() async throws {
        let key = ConversationKey(machineFingerprint: "phone-fp", conversationID: "conv-1")
        var row = summary("conv-1", peer: "")
        row.lifecycleState = "idle"

        let found = try #require(try await lookUp(key, answering: [row]))
        #expect(found.lifecycleState == "idle")
        #expect(found.peerFingerprint == "phone-fp")
        #expect(ConversationKey(conversationID: found.conversationID, peerFingerprint: found.peerFingerprint, via: "fp-1") == key)
    }

    @Test("点名问别的对端发起的会话：发起端为空的那行是调用方自己的，不冒充它；回显了发起端的照键匹配")
    func looksUpOtherOriginsByEchoedPeer() async throws {
        let desktop = ConversationKey(machineFingerprint: "desktop-fp", conversationID: "conv-1")
        #expect(try await lookUp(desktop, answering: [summary("conv-1", peer: "")]) == nil)
        #expect(try await lookUp(desktop, answering: [summary("conv-1", peer: "desktop-fp")])?.peerFingerprint == "desktop-fp")
        // 机器自己发起的（发起端报的是承载机自己的指纹）键落在承载机上，照旧认得；空发起端那行是本机的，不是它。
        let carrierKeyed = ConversationKey(machineFingerprint: "fp-1", conversationID: "conv-1")
        #expect(try await lookUp(carrierKeyed, answering: [summary("conv-1", peer: "fp-1")])?.peerFingerprint == "fp-1")
        #expect(try await lookUp(carrierKeyed, answering: [summary("conv-1", peer: "")]) == nil)
    }

    @Test("保存到手机：attach 带 conversation_id 与发起端指纹，答复最高帧号；pull 的帧载荷是 RpcNotification 字节，createtime 原样")
    func attachAndPull() async throws {
        let harness = await Harness.started()
        let adapter = RelayMachineSessions(connection: harness.connection, caller: "phone-fp")
        async let latest = adapter.attach(conversationID: "conv-1", peerFingerprint: "peer-1", on: "fp-1")
        let (socket, id) = try await harness.machineChannel("fp-1")
        let attach = try await socket.nextRequest(on: id, method: .sessionAttach)
        let attachBody = try attach.body(Agentre_Wire_SessionAttachRequest.self)
        #expect(attachBody.conversationID == "conv-1")
        #expect(attachBody.peerFingerprint == "peer-1")
        var attached = Agentre_Wire_SessionAttachResponse()
        attached.latestSeq = 7
        socket.respond(id, to: attach, with: attached)
        #expect(try await latest == 7)

        async let batch = adapter.pull(conversationID: "conv-1", peerFingerprint: "peer-1", after: 5, on: "fp-1")
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        let pullBody = try pull.body(Agentre_Wire_SessionPullRequest.self)
        #expect(pullBody.conversationID == "conv-1")
        #expect(pullBody.peerFingerprint == "peer-1")
        #expect(pullBody.cursor == 5)
        #expect(pullBody.limit > 0)
        var page = Agentre_Wire_SessionPullResponse()
        page.notifications = [durableFrame(6, createtime: 1_006), durableFrame(7, createtime: 0)]
        page.cursor = 7
        page.hasMore_p = false
        socket.respond(id, to: pull, with: page)

        let frames = try await batch
        #expect(frames.cursor == 7)
        #expect(!frames.hasMore)
        #expect(frames.frames.map(\.seq) == [6, 7])
        #expect(frames.frames.map(\.createtime) == [1_006, 0])
        let decoded = try Agentre_Wire_RpcNotification(serializedBytes: frames.frames[0].payload)
        #expect(decoded == relayTurnStarted("conv-1", seq: 6))
    }

    @Test("保存一条已中断的会话：对端 attach 回 no active turn 不算失败——没有最高帧号可报，历史照拉")
    func interruptedAttachIsNotAFailure() async throws {
        let harness = await Harness.started()
        let adapter = RelayMachineSessions(connection: harness.connection, caller: "phone-fp")
        async let latest = adapter.attach(conversationID: "conv-1", peerFingerprint: "", on: "fp-1")
        let (socket, id) = try await harness.machineChannel("fp-1")
        socket.fail(id, to: try await socket.nextRequest(on: id, method: .sessionAttach), code: -32010, message: "no active turn")
        let reported: Int64? = try await latest
        #expect(reported == nil)
    }

    @Test("错误应答与到期无应答都以不带码、不带原串的领域失败收场", arguments: FailureScenario.allCases)
    func failuresAreDomainFacts(_ scenario: FailureScenario) async throws {
        let list = try await failure(scenario, method: .sessionList, on: "fp-1") { harness in
            try await RelayMachineSessions(connection: harness.connection, caller: "phone-fp").sessions(on: "fp-1", keyword: "", cursor: "", limit: 10)
        }
        #expect(list as? RelayFailure == scenario.expected)
        #expect(!String(describing: list).contains("peer raw string"))

        let counts = try await failure(scenario, method: .sessionCounts, on: "fp-1") { harness in
            try await RelayMachineSessions(connection: harness.connection, caller: "phone-fp").counts(on: "fp-1")
        }
        #expect(counts as? RelayFailure == scenario.expected)

        let attach = try await failure(scenario, method: .sessionAttach, on: "fp-1") { harness in
            try await RelayMachineSessions(connection: harness.connection, caller: "phone-fp").attach(conversationID: "c", peerFingerprint: "", on: "fp-1")
        }
        #expect(attach as? RelayFailure == scenario.expected)

        let pull = try await failure(scenario, method: .sessionPull, on: "fp-1") { harness in
            try await RelayMachineSessions(connection: harness.connection, caller: "phone-fp").pull(conversationID: "c", peerFingerprint: "", after: 0, on: "fp-1")
        }
        #expect(pull as? RelayFailure == scenario.expected)
    }
}

@Suite struct RelayFailureTests {
    @Test("中继调用的每种收场都落到一个领域事实，界面据它用自己的话说")
    func mapsToFacts() {
        #expect(RelayFailure(RelayCallError.timedOut) == .timedOut)
        #expect(RelayFailure(RelayCallError.disconnected) == .connectionLost)
        #expect(RelayFailure(RelayCallError.channelClosed) == .machineUnreachable)
        #expect(RelayFailure(RelayCallError.updateRequired) == .updateRequired)
        #expect(RelayFailure(RelayCallError.unexpectedResponse) == .unrecognisedResponse)
        #expect(RelayFailure(RelayCallError.rejected(code: -32_000)) == .refused)

        #expect(RelayFailure.timedOut.fact == .timedOut)
        #expect(RelayFailure.connectionLost.fact == .serverUnreachable)
        #expect(RelayFailure.machineUnreachable.fact == .noMachineAvailable(.offline))
        #expect(RelayFailure.updateRequired.fact == .updateRequired)
        #expect(RelayFailure.unrecognisedResponse.fact == .unrecognisedResponse)
        #expect(RelayFailure.refused.fact == .unknown)
    }
}
