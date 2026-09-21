import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

/// 机器侧最高帧号低于本机游标时游标回退（对照 mirror_svc.dropCursorAboveHighWater 与桌面端
/// runtimes/remote/reconnect.go 的同名规则）：否则此后每一帧都满足 seq <= 游标、被当重复丢掉，
/// 会话无声冻住。
@Suite struct RelayHighWaterTests {
    @Test("attach 报的最高帧号低于本机游标：从 0 起重拉，此后的实时帧照常交出")
    func cursorAboveHighWaterRewinds() async throws {
        let harness = Harness()
        let target = RelayTarget.machine(fingerprint: "fp-1")
        let (channel, socket, id) = try await harness.readyChannel(target)
        let live = Collected(await channel.subscribe(conversationID: "conv-1"))

        async let attached = channel.attach(conversationID: "conv-1", peerFingerprint: "peer-1", after: 10)
        let attach = try await socket.nextRequest(on: id, method: .sessionAttach)
        var attachResponse = Agentre_Wire_SessionAttachResponse()
        attachResponse.latestSeq = 3
        socket.respond(id, to: attach, with: attachResponse)

        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        let pullRequest = try Agentre_Wire_SessionPullRequest(serializedBytes: pull.request.encodedPayload)
        #expect(pullRequest.cursor == 0)
        var page = Agentre_Wire_SessionPullResponse()
        page.notifications = (Int64(1)...3).map { seq in
            var frame = Agentre_Wire_DurableNotification()
            frame.seq = seq
            frame.payload = relayTurnStarted("conv-1", seq: seq)
            frame.createtime = 1_000 + seq
            return frame
        }
        page.cursor = 3
        socket.respond(id, to: pull, with: page)
        _ = try await attached

        socket.notify(id, relayTurnStarted("conv-1", seq: 4))
        _ = try await eventually("seq 4") { live.items.contains { $0.seq == 4 } ? true : nil }
        #expect(live.items.map(\.seq) == [1, 2, 3, 4])
        #expect(await channel.cursor(conversationID: "conv-1") == 4)
    }

    @Test("游标不高于最高帧号时照旧从游标接着拉")
    func cursorWithinHighWaterKept() async throws {
        let harness = Harness()
        let target = RelayTarget.machine(fingerprint: "fp-1")
        let (channel, socket, id) = try await harness.readyChannel(target)

        async let attached = channel.attach(conversationID: "conv-1", after: 3)
        let attach = try await socket.nextRequest(on: id, method: .sessionAttach)
        var attachResponse = Agentre_Wire_SessionAttachResponse()
        attachResponse.latestSeq = 3
        socket.respond(id, to: attach, with: attachResponse)
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        #expect(try Agentre_Wire_SessionPullRequest(serializedBytes: pull.request.encodedPayload).cursor == 3)
        var page = Agentre_Wire_SessionPullResponse()
        page.cursor = 3
        socket.respond(id, to: pull, with: page)
        _ = try await attached
    }
}

func relayTurnStarted(_ conversationID: String, seq: Int64) -> Agentre_Wire_RpcNotification {
    var started = Agentre_Wire_TurnStartedNotification()
    started.conversationID = conversationID
    started.seq = seq
    var notification = Agentre_Wire_RpcNotification()
    notification.turnStarted = started
    return notification
}

/// 把一条异步流收进数组，测试据它断言。
final class Collected<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Element] = []
    private var ended = false
    var items: [Element] { lock.withLock { stored } }
    var finished: Bool { lock.withLock { ended } }

    init(_ stream: AsyncStream<Element>) {
        Task { [self] in
            for await element in stream { lock.withLock { stored.append(element) } }
            lock.withLock { ended = true }
        }
    }
}
