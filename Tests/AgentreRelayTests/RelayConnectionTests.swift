import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

private func healthResponse(_ uuid: String) -> Agentre_Wire_HealthPingResponse {
    var response = Agentre_Wire_HealthPingResponse()
    response.instanceUuid = uuid
    return response
}

private func turnStarted(_ conversationID: String, seq: Int64) -> Agentre_Wire_RpcNotification {
    var started = Agentre_Wire_TurnStartedNotification()
    started.conversationID = conversationID
    started.seq = seq
    var notification = Agentre_Wire_RpcNotification()
    notification.turnStarted = started
    return notification
}

private func durable(_ conversationID: String, seq: Int64) -> Agentre_Wire_DurableNotification {
    var frame = Agentre_Wire_DurableNotification()
    frame.seq = seq
    frame.payload = turnStarted(conversationID, seq: seq)
    frame.createtime = 1_700_000_000_000 + seq
    return frame
}

/// 收集一条通道交出的通知的 seq。
private final class SeqCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int64] = []
    var seqs: [Int64] { lock.withLock { seen } }

    init(_ channel: RelayChannel) {
        Task { [self] in
            for await notification in channel.notifications {
                lock.withLock { seen.append(notification.seq ?? -1) }
            }
        }
    }
}

@Suite struct RelayConnectionTests {
    // MARK: (a) 一条通道上的并发请求按 id 路由

    @Test("一条通道上并发两个请求，应答乱序到达也各归其主，未知 id 的应答被忽略")
    func concurrentRequestsRouteByID() async throws {
        let harness = Harness()
        let (channel, socket, id) = try await harness.readyChannel(.machine(fingerprint: "fp-1"))

        async let first: Agentre_Wire_HealthPingResponse = channel.call(.healthPing, Agentre_Wire_HealthPingRequest())
        async let second: Agentre_Wire_HealthPingResponse = channel.call(.healthPing, Agentre_Wire_HealthPingRequest())

        let a = try await socket.nextRequest(on: id, method: .healthPing)
        let b = try await socket.nextRequest(on: id, method: .healthPing)
        #expect(a.id != b.id)

        var stray = Agentre_Wire_RpcFrame()
        stray.id = 9_999
        stray.response = Agentre_Wire_Response()
        socket.push(id, try stray.serializedData())
        socket.respond(id, to: b, with: healthResponse("answer-\(b.id)"))
        socket.respond(id, to: a, with: healthResponse("answer-\(a.id)"))

        let (r1, r2) = try await (first, second)
        #expect(Set([r1.instanceUuid, r2.instanceUuid]) == ["answer-\(a.id)", "answer-\(b.id)"])
        #expect(r1.instanceUuid != r2.instanceUuid)
    }

    // MARK: (b) 两种寻址共用一条物理连接

    @Test("conversation: 与 machine: 两条通道共存于同一条物理连接，各收各的帧")
    func twoTargetsShareOneSocket() async throws {
        let harness = Harness()
        await harness.connection.start()
        let conversation = await harness.connection.channel(for: .conversation(id: "conv-1"))
        let machine = await harness.connection.channel(for: .machine(fingerprint: "fp-9"))
        let socket = try await harness.dialer.socket(0)

        let conversationID = try await socket.channelID(for: .conversation(id: "conv-1"))
        let machineID = try await socket.channelID(for: .machine(fingerprint: "fp-9"))
        #expect(conversationID != machineID)
        #expect(!conversationID.hasPrefix("~") && !machineID.hasPrefix("~"))
        try await socket.acceptHandshake(on: conversationID)
        try await socket.acceptHandshake(on: machineID)
        try await waitStatus(conversation, .ready)
        try await waitStatus(machine, .ready)

        async let onConversation: Agentre_Wire_HealthPingResponse = conversation.call(.healthPing, Agentre_Wire_HealthPingRequest())
        async let onMachine: Agentre_Wire_HealthPingResponse = machine.call(.healthPing, Agentre_Wire_HealthPingRequest())
        let toMachine = try await socket.nextRequest(on: machineID, method: .healthPing)
        let toConversation = try await socket.nextRequest(on: conversationID, method: .healthPing)
        socket.respond(machineID, to: toMachine, with: healthResponse("machine"))
        socket.respond(conversationID, to: toConversation, with: healthResponse("conversation"))

        #expect(try await onConversation.instanceUuid == "conversation")
        #expect(try await onMachine.instanceUuid == "machine")
        #expect(harness.dialer.dials.count == 1)
        #expect(harness.dialer.sockets.count == 1)
        // 同一目标再要一次得到的是同一条通道，不会再开一条。
        let again = await harness.connection.channel(for: .machine(fingerprint: "fp-9"))
        #expect(again === machine)
        #expect(socket.declarations.count == 2)
    }

    // MARK: (c) 逐通道握手出示设备 access token

    @Test("拨号与每条通道的 auth.account 都出示设备 access token，并带上本端协议版本")
    func handshakePresentsAccessToken() async throws {
        let harness = Harness()
        await harness.connection.start()
        _ = await harness.connection.channel(for: .conversation(id: "conv-1"))
        _ = await harness.connection.channel(for: .machine(fingerprint: "fp-2"))
        let socket = try await harness.dialer.socket(0)

        #expect(harness.dialer.dials.map(\.token) == ["token-1"])
        #expect(harness.dialer.dials.map(\.url) == [testURL])
        for target in [RelayTarget.conversation(id: "conv-1"), .machine(fingerprint: "fp-2")] {
            let id = try await socket.channelID(for: target)
            // 声明是这条通道的第一帧，握手紧随其后。
            #expect(socket.frames.first { $0.channelID == id }?.payload == Data(target.declaration.utf8))
            let request = try await socket.acceptHandshake(on: id)
            #expect(request.credential == "token-1")
            #expect(request.protocolVersion == RelayProtocol.version)
            #expect(request.minSupportedProtocolVersion == RelayProtocol.version)
        }
    }

    @Test("握手完成前发起的调用先排着，握手后才发出")
    func callsWaitForHandshake() async throws {
        let harness = Harness()
        await harness.connection.start()
        let channel = await harness.connection.channel(for: .machine(fingerprint: "fp-1"))
        let socket = try await harness.dialer.socket(0)
        let id = try await socket.channelID(for: .machine(fingerprint: "fp-1"))

        async let ping: Agentre_Wire_HealthPingResponse = channel.call(.healthPing, Agentre_Wire_HealthPingRequest())
        _ = try await eventually("auth request") { socket.requests(on: id, method: .authAccount).first }
        try await Task.sleep(for: .milliseconds(20))
        #expect(socket.requests(on: id, method: .healthPing).isEmpty)

        try await socket.acceptHandshake(on: id)
        let request = try await socket.nextRequest(on: id, method: .healthPing)
        socket.respond(id, to: request, with: healthResponse("ok"))
        #expect(try await ping.instanceUuid == "ok")
    }

    // MARK: (d) 断线补齐

    @Test("断线后重拨、重握手（出示新令牌）、重 attach、按游标 pull；重复帧只应用一次")
    func reconnectCatchesUpBySeq() async throws {
        let harness = Harness()
        let target = RelayTarget.conversation(id: "conv-1")
        let (channel, socket, id) = try await harness.readyChannel(target)
        let seen = SeqCollector(channel)

        // 首次关注：从本地已有的 seq 3 起 attach + pull。
        async let attached = channel.attach(conversationID: "conv-1", after: 3)
        let attach = try await socket.nextRequest(on: id, method: .sessionAttach)
        #expect(try Agentre_Wire_SessionAttachRequest(serializedBytes: attach.request.encodedPayload).conversationID == "conv-1")
        var attachResponse = Agentre_Wire_SessionAttachResponse()
        attachResponse.latestSeq = 5
        socket.respond(id, to: attach, with: attachResponse)
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        #expect(try Agentre_Wire_SessionPullRequest(serializedBytes: pull.request.encodedPayload).cursor == 3)
        var page = Agentre_Wire_SessionPullResponse()
        page.notifications = [durable("conv-1", seq: 4), durable("conv-1", seq: 5)]
        page.cursor = 5
        socket.respond(id, to: pull, with: page)
        #expect(try await attached.latestSeq == 5)

        // 实时帧 5 与补齐页重复，只应用一次。
        socket.notify(id, turnStarted("conv-1", seq: 5))
        socket.notify(id, turnStarted("conv-1", seq: 6))
        _ = try await eventually("seq 6") { seen.seqs.contains(6) ? true : nil }

        // 断网；令牌在此期间被刷新。
        harness.token.value = "token-2"
        socket.drop()
        try await waitStatus(channel, .reconnecting)
        let delay = try await eventually("redial backoff") { harness.clock.pendingSleeps.first }
        harness.clock.advance(by: delay)

        let second = try await harness.dialer.socket(1)
        #expect(harness.dialer.dials.map(\.token) == ["token-1", "token-2"])
        let newID = try await second.channelID(for: target)
        let handshake = try await second.acceptHandshake(on: newID)
        #expect(handshake.credential == "token-2")

        let reattach = try await second.nextRequest(on: newID, method: .sessionAttach)
        // 断线期间机器又往前走了：重新 attach 报的最高帧号不低于本机游标（低于时游标要回退，
        // 见 RelayHighWaterTests）。
        var reattachResponse = Agentre_Wire_SessionAttachResponse()
        reattachResponse.latestSeq = 9
        second.respond(newID, to: reattach, with: reattachResponse)
        let repull = try await second.nextRequest(on: newID, method: .sessionPull)
        let repullRequest = try Agentre_Wire_SessionPullRequest(serializedBytes: repull.request.encodedPayload)
        #expect(repullRequest.conversationID == "conv-1")
        #expect(repullRequest.cursor == 6)

        // 补齐期间到的实时帧 9 要排在补齐页之后，不能把游标顶过缺口。
        second.notify(newID, turnStarted("conv-1", seq: 9))
        var firstPage = Agentre_Wire_SessionPullResponse()
        firstPage.notifications = [durable("conv-1", seq: 6), durable("conv-1", seq: 7)]
        firstPage.cursor = 7
        firstPage.hasMore_p = true
        second.respond(newID, to: repull, with: firstPage)
        let more = try await second.nextRequest(on: newID, method: .sessionPull)
        #expect(try Agentre_Wire_SessionPullRequest(serializedBytes: more.request.encodedPayload).cursor == 7)
        var lastPage = Agentre_Wire_SessionPullResponse()
        lastPage.notifications = [durable("conv-1", seq: 7), durable("conv-1", seq: 8)]
        lastPage.cursor = 8
        second.respond(newID, to: more, with: lastPage)

        _ = try await eventually("seq 9") { seen.seqs.contains(9) ? true : nil }
        second.notify(newID, turnStarted("conv-1", seq: 9))
        second.notify(newID, turnStarted("conv-1", seq: 10))
        _ = try await eventually("seq 10") { seen.seqs.contains(10) ? true : nil }
        #expect(seen.seqs == [4, 5, 6, 7, 8, 9, 10])
        #expect(await channel.cursor(conversationID: "conv-1") == 10)
    }

    // MARK: (e) 协议版本不等

    @Test("握手因版本不等被拒：该通道停止重试、给出「需更新 App」事实；同连接另一条通道不受影响")
    func versionMismatchStopsThatChannel() async throws {
        let harness = Harness()
        await harness.connection.start()
        let conversation = await harness.connection.channel(for: .conversation(id: "conv-1"))
        let machine = await harness.connection.channel(for: .machine(fingerprint: "fp-1"))
        let socket = try await harness.dialer.socket(0)
        let conversationID = try await socket.channelID(for: .conversation(id: "conv-1"))
        let machineID = try await socket.channelID(for: .machine(fingerprint: "fp-1"))

        let peerText = "protocol version 0.3.0 not supported (peer accepts 0.3.0..0.3.0)"
        let auth = try await socket.nextRequest(on: conversationID, method: .authAccount)
        socket.fail(conversationID, to: auth, code: RelayProtocol.errorCodeProtocolVersion, message: peerText)
        try await socket.acceptHandshake(on: machineID)

        try await waitStatus(conversation, .updateRequired)
        try await waitStatus(machine, .ready)
        // 状态流把这一事实推给观察方（界面据它提示更新 App）。
        var updates: [RelayChannelStatus] = []
        for await update in conversation.statusUpdates {
            updates.append(update)
            if update == .updateRequired { break }
        }
        #expect(updates.last == .updateRequired)
        let status = await conversation.status
        #expect(!String(describing: status).contains("0.3.0"))
        #expect(!String(describing: status).contains("32006"))
        // 服务端那侧也被告知这条通道关了（空载荷）。
        _ = try await eventually("close frame") {
            socket.frames.contains { $0.channelID == conversationID && $0.payload.isEmpty } ? true : nil
        }
        await #expect(throws: RelayCallError.updateRequired) {
            let _: Agentre_Wire_HealthPingResponse = try await conversation.call(.healthPing, Agentre_Wire_HealthPingRequest())
        }

        // 不排任何重试：时间怎么推都不会再握一次。
        #expect(harness.clock.pendingSleeps.isEmpty)
        harness.clock.advance(by: .seconds(3600))

        // 换了物理连接也不再为它声明、握手；另一条照常重握手。
        socket.drop()
        let delay = try await eventually("redial backoff") { harness.clock.pendingSleeps.first }
        harness.clock.advance(by: delay)
        let second = try await harness.dialer.socket(1)
        let newMachineID = try await second.channelID(for: .machine(fingerprint: "fp-1"))
        try await second.acceptHandshake(on: newMachineID)
        try await waitStatus(machine, .ready)
        #expect(second.declarations[RelayTarget.conversation(id: "conv-1").declaration] == nil)
        #expect(socket.requests(on: conversationID, method: .authAccount).count == 1)
        #expect(await conversation.status == .updateRequired)
    }

    @Test("对端握手应答里报的协议版本不等，同样判为需要更新 App")
    func versionMismatchInResponse() async throws {
        let harness = Harness()
        await harness.connection.start()
        let channel = await harness.connection.channel(for: .machine(fingerprint: "fp-1"))
        let socket = try await harness.dialer.socket(0)
        let id = try await socket.channelID(for: .machine(fingerprint: "fp-1"))
        let auth = try await socket.nextRequest(on: id, method: .authAccount)
        var response = Agentre_Wire_AuthAccountResponse()
        response.ok = true
        response.protocolVersion = "9.9.9"
        socket.respond(id, to: auth, with: response)
        try await waitStatus(channel, .updateRequired)
    }

    @Test("其它握手失败（如凭据被拒）按退让重试，不判为需要更新")
    func otherHandshakeFailureRetries() async throws {
        let harness = Harness()
        await harness.connection.start()
        let channel = await harness.connection.channel(for: .machine(fingerprint: "fp-1"))
        let socket = try await harness.dialer.socket(0)
        let id = try await socket.channelID(for: .machine(fingerprint: "fp-1"))
        let auth = try await socket.nextRequest(on: id, method: .authAccount)
        socket.fail(id, to: auth, code: -32001, message: "account credential expired")

        try await waitStatus(channel, .reconnecting)
        let delay = try await eventually("handshake retry") {
            harness.clock.pendingSleeps.first { $0 != .seconds(30) }
        }
        #expect(delay == .milliseconds(750))
        harness.clock.advance(by: delay)
        try await socket.acceptHandshake(on: id)
        try await waitStatus(channel, .ready)
    }

    // MARK: (f) 重拨：指数退让、封顶、抖动

    @Test("拨不通时按指数退让重拨，封顶 30 秒，抖动来自注入的随机源")
    func redialBackoff() async throws {
        let harness = Harness(failFirstDials: 7, random: [0.5, 0.5, 0.5, 0, 1, 0.5, 0.5])
        await harness.connection.start()
        let channel = await harness.connection.channel(for: .machine(fingerprint: "fp-1"))

        var delays: [Duration] = []
        for attempt in 1...7 {
            _ = try await eventually("dial #\(attempt)") { harness.dialer.dials.count == attempt ? true : nil }
            let delay = try await eventually("backoff #\(attempt)") { harness.clock.pendingSleeps.first }
            #expect(harness.dialer.dials.count == attempt) // 退让到期前不重拨
            delays.append(delay)
            harness.clock.advance(by: delay)
        }
        #expect(delays == [
            .milliseconds(750), .milliseconds(1500), .seconds(3), .seconds(4),
            .seconds(16), .milliseconds(22500), .milliseconds(22500),
        ])

        let socket = try await harness.dialer.socket(0)
        let id = try await socket.channelID(for: .machine(fingerprint: "fp-1"))
        try await socket.acceptHandshake(on: id)
        try await waitStatus(channel, .ready)

        // 连上过之后退让从头算起。
        socket.drop()
        let next = try await eventually("backoff after success") { harness.clock.pendingSleeps.first }
        #expect(next == .milliseconds(750))
    }

    // MARK: (g) 无人应答的 RPC 到期收场

    @Test("无人应答的调用到期抛 timedOut，并向对端发出取消")
    func unansweredCallTimesOut() async throws {
        let harness = Harness()
        let (channel, socket, id) = try await harness.readyChannel(.machine(fingerprint: "fp-1"))

        let ping = Task { () async throws -> Agentre_Wire_HealthPingResponse in
            try await channel.call(.healthPing, Agentre_Wire_HealthPingRequest())
        }
        let request = try await socket.nextRequest(on: id, method: .healthPing)
        let deadline = try await eventually("deadline") { harness.clock.pendingSleeps.first }
        #expect(deadline == RelayChannel.defaultDeadline)

        harness.clock.advance(by: deadline - .milliseconds(1))
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.clock.pendingSleeps.count == 1) // 期限前仍在等

        harness.clock.advance(by: .milliseconds(1))
        await #expect(throws: RelayCallError.timedOut) { _ = try await ping.value }
        let cancel = try await eventually("cancel frame") {
            socket.rpcFrames(on: id).first { if case .cancel? = $0.body { true } else { false } }
        }
        #expect(cancel.cancel.requestID == request.id)
        // 迟到的应答不会让任何东西崩掉或重复落定。
        socket.respond(id, to: request, with: healthResponse("late"))
    }

    @Test("连接断开时，已发出而未应答的调用立即以 disconnected 收场")
    func inflightCallFailsOnDisconnect() async throws {
        let harness = Harness()
        let (channel, socket, id) = try await harness.readyChannel(.machine(fingerprint: "fp-1"))
        let ping = Task { () async throws -> Agentre_Wire_HealthPingResponse in
            try await channel.call(.healthPing, Agentre_Wire_HealthPingRequest())
        }
        _ = try await socket.nextRequest(on: id, method: .healthPing)
        socket.drop()
        await #expect(throws: RelayCallError.disconnected) { _ = try await ping.value }
    }

    // MARK: 账号信号保留通道

    @Test("保留信号通道的帧原样交给订阅方，空载荷表示信号那一路关了")
    func signalChannel() async throws {
        let harness = Harness()
        await harness.connection.start()
        let socket = try await harness.dialer.socket(0)
        var iterator = harness.connection.signals.makeAsyncIterator()

        socket.push(RelayProtocol.signalChannelID, Data([1, 2, 3]))
        #expect(await iterator.next() == .frame(Data([1, 2, 3])))
        socket.push(RelayProtocol.signalChannelID, Data())
        #expect(await iterator.next() == .closed)
        #expect(!socket.frames.contains { $0.channelID == RelayProtocol.signalChannelID })
    }
}
