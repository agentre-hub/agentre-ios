import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

private func page(_ conversationID: String, _ seqs: [Int64], hasMore: Bool = false) -> Agentre_Wire_SessionPullResponse {
    var page = Agentre_Wire_SessionPullResponse()
    page.notifications = seqs.map { seq in
        var frame = Agentre_Wire_DurableNotification()
        frame.seq = seq
        frame.payload = relayTurnStarted(conversationID, seq: seq)
        frame.createtime = 1_000 + seq
        return frame
    }
    page.cursor = seqs.last ?? 0
    page.hasMore_p = hasMore
    return page
}

private func attachResponse(latestSeq: Int64) -> Agentre_Wire_SessionAttachResponse {
    var response = Agentre_Wire_SessionAttachResponse()
    response.latestSeq = latestSeq
    return response
}

/// 不带号的轮次边界帧（run_result_done）。
private func runDone(_ conversationID: String) -> Agentre_Wire_RpcNotification {
    var done = Agentre_Wire_RunResultDoneNotification()
    done.conversationID = conversationID
    var notification = Agentre_Wire_RpcNotification()
    notification.runResultDone = done
    return notification
}

/// 补齐与游标的几条边界：调用方的游标说了算、同一对话的补齐不并行、缺号即补拉、
/// 补齐期间的轮次边界排在补齐帧之后。
@Suite struct RelayCatchUpTests {
    @Test("再次 attach 时从调用方给的游标起拉：通道自己的游标跑在前面也不能跳过调用方没拿到的帧")
    func callerCursorWins() async throws {
        let harness = Harness()
        let (channel, socket, id) = try await harness.readyChannel(.machine(fingerprint: "fp-1"))

        async let first = channel.attach(conversationID: "conv-1", after: 5)
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .sessionAttach), with: attachResponse(latestSeq: 8))
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .sessionPull), with: page("conv-1", [6, 7, 8]))
        _ = try await first
        #expect(await channel.cursor(conversationID: "conv-1") == 8)

        // 本地库只落到了 5（上一次跟随中途断了）：从 5 接着拉。
        async let second = channel.attach(conversationID: "conv-1", after: 5)
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .sessionAttach), with: attachResponse(latestSeq: 8))
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        #expect(try pull.body(Agentre_Wire_SessionPullRequest.self).cursor == 5)
        socket.respond(id, to: pull, with: page("conv-1", [6, 7, 8]))
        _ = try await second
    }

    @Test("同一对话的两次 attach 不并行补齐：前一轮失败也不会丢掉后一轮期间到达的实时帧")
    func catchUpsAreSerialised() async throws {
        let harness = Harness()
        let (channel, socket, id) = try await harness.readyChannel(.machine(fingerprint: "fp-1"))
        let live = Collected(await channel.subscribe(conversationID: "conv-1"))

        // 哪一个先排上不定：先排上的那一轮失败，另一轮接在它后面从头补齐。
        let first = Task { try await channel.attach(conversationID: "conv-1") }
        let second = Task { try await channel.attach(conversationID: "conv-1") }
        let attach = try await socket.nextRequest(on: id, method: .sessionAttach)
        try await Task.sleep(for: .milliseconds(50))
        #expect(socket.requests(on: id, method: .sessionAttach).count == 1)

        socket.respond(id, to: attach, with: attachResponse(latestSeq: 2))
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        socket.notify(id, relayTurnStarted("conv-1", seq: 3))
        socket.fail(id, to: pull, code: -32603, message: "boom")

        socket.respond(id, to: try await socket.nextRequest(on: id, method: .sessionAttach), with: attachResponse(latestSeq: 3))
        let repull = try await socket.nextRequest(on: id, method: .sessionPull)
        #expect(try repull.body(Agentre_Wire_SessionPullRequest.self).cursor == 0)
        socket.respond(id, to: repull, with: page("conv-1", [1, 2, 3]))
        let outcomes = [await first.result, await second.result]
        #expect(outcomes.count { (try? $0.get()) != nil } == 1)

        socket.notify(id, relayTurnStarted("conv-1", seq: 4))
        _ = try await eventually("seq 4") { live.items.contains { $0.seq == 4 } ? true : nil }
        #expect(live.items.map(\.seq) == [1, 2, 3, 4])
    }

    @Test("实时帧跳号（中间一帧丢了）：先按游标补拉缺口，再交出这一帧")
    func liveGapIsPulled() async throws {
        let harness = Harness()
        let (channel, socket, id) = try await harness.readyChannel(.machine(fingerprint: "fp-1"))
        let live = Collected(await channel.subscribe(conversationID: "conv-1"))

        async let attached = channel.attach(conversationID: "conv-1")
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .sessionAttach), with: attachResponse(latestSeq: 1))
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .sessionPull), with: page("conv-1", [1]))
        _ = try await attached

        socket.notify(id, relayTurnStarted("conv-1", seq: 3))
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .sessionAttach), with: attachResponse(latestSeq: 3))
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        #expect(try pull.body(Agentre_Wire_SessionPullRequest.self).cursor == 1)
        socket.respond(id, to: pull, with: page("conv-1", [2, 3]))

        _ = try await eventually("seq 3") { live.items.contains { $0.seq == 3 } ? true : nil }
        #expect(live.items.map(\.seq) == [1, 2, 3])
    }

    @Test("补齐期间到达的轮次边界帧排在补齐帧之后交出，不抢到它所属那一轮的帧前面")
    func boundaryDuringCatchUpWaits() async throws {
        let harness = Harness()
        let (channel, socket, id) = try await harness.readyChannel(.machine(fingerprint: "fp-1"))
        let live = Collected(await channel.subscribe(conversationID: "conv-1"))

        async let attached = channel.attach(conversationID: "conv-1")
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .sessionAttach), with: attachResponse(latestSeq: 2))
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        socket.notify(id, runDone("conv-1"))
        try await Task.sleep(for: .milliseconds(50))
        socket.respond(id, to: pull, with: page("conv-1", [1, 2]))
        _ = try await attached

        _ = try await eventually("three frames") { live.items.count == 3 ? true : nil }
        #expect(live.items.map(\.seq) == [1, 2, nil])
    }

    @Test("会话已中断（对端 attach 回 no active turn）：历史照拉，attach 不算失败")
    func interruptedConversationStillPulls() async throws {
        let harness = Harness()
        let (channel, socket, id) = try await harness.readyChannel(.machine(fingerprint: "fp-1"))
        let live = Collected(await channel.subscribe(conversationID: "conv-1"))

        async let attached = channel.attach(conversationID: "conv-1")
        socket.fail(id, to: try await socket.nextRequest(on: id, method: .sessionAttach), code: -32010, message: "no active turn")
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        socket.respond(id, to: pull, with: page("conv-1", [1, 2]))
        let response = try await attached

        #expect(response.lifecycleState == SavedConversation.Lifecycle.interrupted)
        #expect(response.latestSeq == 2)
        _ = try await eventually("seq 2") { live.items.contains { $0.seq == 2 } ? true : nil }
        #expect(live.items.map(\.seq) == [1, 2])
    }

    @Test("调用方被取消：调用当场以取消收场，并向对端发出取消，不等到兜底期限")
    func cancelledCallSettlesAtOnce() async throws {
        let harness = Harness()
        let (channel, socket, id) = try await harness.readyChannel(.machine(fingerprint: "fp-1"))

        let ping = Task { () async throws -> Agentre_Wire_HealthPingResponse in
            try await channel.call(.healthPing, Agentre_Wire_HealthPingRequest())
        }
        let request = try await socket.nextRequest(on: id, method: .healthPing)
        ping.cancel()

        let settled = Collected(AsyncStream { continuation in
            Task {
                continuation.yield(await ping.result)
                continuation.finish()
            }
        })
        let outcome = try await eventually("cancelled call settled") { settled.items.first }
        #expect(throws: CancellationError.self) { try outcome.get() }
        let cancel = try await eventually("cancel frame") {
            socket.rpcFrames(on: id).first { if case .cancel? = $0.body { true } else { false } }
        }
        #expect(cancel.cancel.requestID == request.id)
    }
}
