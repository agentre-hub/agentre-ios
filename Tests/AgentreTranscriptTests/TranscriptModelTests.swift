import AgentreDomain
import Foundation
@testable import AgentreUI
import Testing

/// 历史先读本地库、不足时经 pull 向后补，与实时帧按 seq 合流；上滚即停自动跟随。
@MainActor
@Suite("转录视图模型")
struct TranscriptModelTests {
    let decoder = FakeDecoder()

    func frames(_ range: ClosedRange<Int64>) -> [TranscriptFrame] {
        range.map { stored(decoder, $0, .userMessage("m\($0)")) }
    }

    func userTexts(_ model: TranscriptModel) -> [String] {
        model.document.messages.filter { $0.role == .user }.map(\.text)
    }

    func model(local: [TranscriptFrame], machine: [TranscriptFrame] = [], pageSize: Int = 50) -> (TranscriptModel, FakeStore, FakeRelay) {
        let store = FakeStore(local)
        let relay = FakeRelay(machineFrames: machine)
        let conversation = SavedConversation(key: conversationKey, peerFingerprint: "peer-1", lifecycleState: "idle")
        return (TranscriptModel(conversation: conversation, store: store, relay: relay, decoder: decoder, pageSize: pageSize), store, relay)
    }

    @Test("本地库够一页：直接读本地，不向机器要历史")
    func localIsEnough() async {
        let (model, store, relay) = model(local: frames(1...60))
        await model.load()
        #expect(userTexts(model).count == 60)
        #expect(await relay.pulls.isEmpty)
        #expect(await store.transcriptReads == 1)
    }

    @Test("本地不足一页：从本地最早帧往前补一页，带上发起端指纹；补回的与本地重叠处只留一份")
    func backfillsWhenInsufficient() async {
        let (model, _, relay) = model(local: frames(40...45), machine: frames(1...45), pageSize: 50)
        await model.load()
        let pulls = await relay.pulls
        #expect(pulls.map(\.cursor) == [0])
        #expect(pulls.first?.peer == "peer-1")
        #expect(pulls.first?.limit == 50)
        #expect(userTexts(model) == (1...45).map { "m\($0)" })
        #expect(!model.hasOlder)
    }

    @Test("本地为空：从头拉，直到机器说没有更多")
    func emptyLocalPullsFromStart() async {
        let (model, _, relay) = model(local: [], machine: frames(1...7), pageSize: 3)
        await model.load()
        #expect(await relay.pulls.map(\.cursor) == [0, 3, 6])
        #expect(userTexts(model) == (1...7).map { "m\($0)" })
        #expect(!model.hasOlder)
    }

    @Test("向后翻页：按 oldest_seq 定起点、按 has_more 续拉，只收本地最早帧之前的；到机器最早帧为止")
    func pagesOlderHistory() async {
        let (model, _, relay) = model(local: frames(101...150), machine: frames(1...150), pageSize: 50)
        await model.load()
        #expect(await relay.pulls.isEmpty)
        #expect(model.hasOlder)

        await model.loadOlder()
        #expect(await relay.pulls.map(\.cursor) == [50])
        #expect(userTexts(model).first == "m51")
        #expect(userTexts(model).count == 100)
        #expect(model.hasOlder)

        await model.loadOlder()
        #expect(await relay.pulls.map(\.cursor) == [50, 0])
        #expect(userTexts(model) == (1...150).map { "m\($0)" })
        #expect(!model.hasOlder)

        await model.loadOlder()
        #expect(await relay.pulls.count == 2)
    }

    @Test("机器已丢掉更早的帧：从它报的 oldest_seq 起补，补到它为止就不再有更早的")
    func respectsOldestSeq() async {
        let (model, _, relay) = model(local: frames(90...95), machine: frames(80...95), pageSize: 50)
        await model.load()
        #expect(userTexts(model).first == "m80")
        #expect(!model.hasOlder)
        #expect(await relay.pulls.count == 1)
    }

    @Test("拉历史失败：本地内容照常可读")
    func offlineStillReadable() async {
        let store = FakeStore(frames(1...3))
        let conversation = SavedConversation(key: conversationKey, peerFingerprint: "", lifecycleState: "idle")
        let model = TranscriptModel(conversation: conversation, store: store, relay: FailingRelay(), decoder: decoder, pageSize: 50)
        await model.load()
        #expect(userTexts(model).count == 3)
    }

    @Test("实时帧与本地历史按 seq 合流：重复帧号不重复出现，不带号的轮次边界让这一轮落定")
    func mergesLiveFrames() async throws {
        let local = [stored(decoder, 1, .userMessage("修构建")), stored(decoder, 2, .turnStarted), stored(decoder, 3, .toolCall(readUse("a")))]
        let (model, _, relay) = model(local: local)
        await model.load()
        #expect(model.document.running)
        let attach = Task { await model.attach() }
        await relay.push(liveFrame(decoder, 3, .toolCall(readUse("a"))))
        await relay.push(liveFrame(decoder, 4, .toolCall(readUse("b"))))
        await relay.push(liveFrame(decoder, nil, .turnDone(TurnDone(durationMs: 1200))))
        try await eventually("live frames merged") { !model.document.running }
        let blocks = model.document.messages.last?.blocks ?? []
        #expect(blocks == [.toolUse(readUse("a")), .toolUse(readUse("b"))])
        #expect(await relay.attaches.first?.peer == "peer-1")
        await relay.finish()
        await attach.value
    }

    @Test("预览尾巴：逐片接在最后一条助手消息上；更新的持久帧与不带号的边界取代它，补回的更早帧、重复帧不取代，帧号回退时一并丢掉")
    func previewTailFollowsTheTimelineRules() async throws {
        let (model, _, _) = model(local: [stored(decoder, 1, .userMessage("写")), stored(decoder, 5, .turnStarted)])
        await model.load()
        func live() -> (text: String, thinking: String) { (model.document.liveText, model.document.liveThinking) }
        model.merge(live: [liveFrame(decoder, nil, .thinkingDelta("想"), preview: true), liveFrame(decoder, nil, .textDelta("第一"), preview: true)])
        model.merge(live: [liveFrame(decoder, nil, .toolCall(readUse("x")), preview: true), liveFrame(decoder, nil, .textDelta("句"), preview: true)])
        #expect(live() == ("第一句", "想"))
        #expect(model.rows.contains { $0.content == .text("第一句", streaming: true) })
        model.merge(live: [liveFrame(decoder, 3, .userMessage("更早的"))])
        model.merge(live: [liveFrame(decoder, 5, .turnStarted)])
        #expect(live() == ("第一句", "想"))
        model.merge(live: [liveFrame(decoder, 6, .textDelta("第一句"))])
        #expect(live() == ("", ""))
        model.merge(live: [liveFrame(decoder, nil, .textDelta("第二"), preview: true)])
        #expect(live() == ("第二", ""))
        model.merge(live: [liveFrame(decoder, nil, .turnDone(TurnDone()))])
        #expect(live() == ("", ""))
        model.merge(live: [liveFrame(decoder, nil, .textDelta("第三"), preview: true)])
        model.merge(live: [LiveTranscriptFrame(seq: nil, createtime: nil, payload: Data(), rewoundTo: 0)])
        #expect(live() == ("", ""))
        #expect(model.document.messages.isEmpty)
    }

    @Test("真实形状的长回复（一万多片、每片一两个字的预览帧）：写到末尾时每一片合进转录的代价仍远小于片与片的间隔，转录不会越流越落后")
    func previewDeltaCostDoesNotGrowWithReply() async throws {
        let (model, _, _) = model(local: [stored(decoder, 1, .userMessage("写一篇操作系统长文")), stored(decoder, 2, .turnStarted)])
        await model.load()
        let deltas = realisticReply(operatingSystemsEssay).map { liveFrame(decoder, nil, $0, preview: true) }
        var next = 0
        /// 合到第 `count` 片为止，再逐片合 200 片所花的时间；连量三轮取最短的，机器被别的活占满时不算进代价。
        func costOfDeltas(after count: Int) -> Duration {
            while next < count { model.merge(live: [deltas[next]]); next += 1 }
            var fastest = Duration.seconds(3_600)
            for _ in 0..<3 {
                let clock = ContinuousClock()
                let started = clock.now
                for _ in 0..<200 { model.merge(live: [deltas[next]]); next += 1 }
                fastest = min(fastest, clock.now - started)
            }
            return fastest
        }
        let short = costOfDeltas(after: 300)
        let long = costOfDeltas(after: deltas.count - 600)
        #expect(model.document.liveText.count > 15_000)
        // 正文越长，拷贝它的那一点代价免不了；要守的是它远小于片与片之间的间隔（真实约 52 片/秒，200 片约 4 秒）。
        // 修前实测：第 300 片后 200 片 0.05 秒，第 11623 片后 1.4 秒（每片 7 毫秒，随回复线性变大）。
        #expect(long < .milliseconds(200), "\(deltas.count) 片的回复：第 300 片后 200 片最快花 \(short)，第 \(deltas.count - 600) 片后花 \(long)")
    }

    @Test("实时流一下涌来几十帧：屏上并着交，不丢帧；上滚着时每一条新行照样记进「回到最新」")
    func burstOfLiveFramesIsCoalescedWithoutLosingRows() async throws {
        let (model, _, relay) = model(local: frames(1...60))
        await model.load()
        model.userScrolledAway()
        let attach = Task { await model.attach() }
        for seq in Int64(61)...90 { await relay.push(liveFrame(decoder, seq, .userMessage("m\(seq)"))) }
        await relay.push(liveFrame(decoder, nil, .textDelta("尾"), preview: true))
        try await eventually("burst shown") { userTexts(model).count == 90 && model.document.liveText == "尾" }
        #expect(userTexts(model) == (1...90).map { "m\($0)" })
        #expect(model.follow.unseen == 31)
        await relay.finish()
        await attach.value
    }

    @Test("看不到的时候（后台、断线）收场的一轮：收场帧补拉不回来，机器报的会话已不在运行即让转录落定；报在运行不动")
    func reconcileEndsTheUnseenTurn() async throws {
        let spawn = use("sp", "Task", input: ["prompt": "go", "run_in_background": .bool(false)], canonical: Canonical(kind: "agent.spawn"))
        let local = [stored(decoder, 1, .userMessage("修构建")), stored(decoder, 2, .toolCall(spawn))]
        let (model, _, relay) = model(local: local)
        await model.load()
        func spawnStatus() -> String? {
            guard case .toolUse(let tool)? = model.document.messages.last?.blocks.first else { return nil }
            return tool.subagent?.status
        }

        let attach = Task { await model.attach() }
        await relay.push(liveFrame(decoder, nil, .turnStarted))
        await relay.push(liveFrame(decoder, 3, .subagent(SubagentUpdate(toolCallID: "sp", phase: .started, info: SubagentState(taskID: "t", status: "running", kind: "local_agent")))))
        try await eventually("turn running") { model.document.running }
        // 只等到 running 不够：子代理的 started 帧（seq 3）是另一条实时帧，接流循环可能还没把它
        // 合进模型（合入与交屏按 liveInterval 节流），高负载下会在它到位前就走到下面的 reconcile，
        // 那时子代理还没在模型里、自然收不到 canceled。等它在模型里显出 running 再收场。
        try await eventually("subagent frame merged into the model") { spawnStatus() == "running" }

        model.reconcile(lifecycle: SavedConversation.Lifecycle.running)
        #expect(model.document.running)
        model.reconcile(lifecycle: SavedConversation.Lifecycle.idle)
        #expect(!model.document.running)
        #expect(spawnStatus() == "canceled")
        await relay.finish()
        await attach.value
    }

    @Test("一轮刚开始、还没到交屏的点，机器就报它已不在运行：按实时流已合进来的转录判断，这一轮照样落定")
    func reconcileSeesLiveFramesNotYetShown() async throws {
        let relay = HandOffRelay()
        let conversation = SavedConversation(key: conversationKey, peerFingerprint: "peer-1", lifecycleState: "idle")
        let model = TranscriptModel(conversation: conversation, store: FakeStore(frames(1...60)), relay: relay, decoder: decoder)
        await model.load()
        let attach = Task { await model.attach() }
        // 第一帧当场交屏；紧接着的开轮帧落在同一个交屏间隔里，合进来了、还没交出去。
        await relay.handOff(liveFrame(decoder, 61, .userMessage("跑一下测试")))
        await relay.handOff(liveFrame(decoder, 62, .turnStarted))
        await relay.handOff(liveFrame(decoder, nil, .toolCall(readUse("x")), preview: true))

        model.reconcile(lifecycle: SavedConversation.Lifecycle.idle)
        try await Task.sleep(for: TranscriptModel.liveInterval * 2)
        #expect(!model.document.running)
        relay.finish()
        await attach.value
    }

    @Test("机器上这条会话的帧号重新起算了（会话删了、会话号被复用）：转录丢掉旧编号下的内容，重拉回来的同号帧不被当成重复")
    func rewindReplacesTheTranscript() async throws {
        let (model, _, relay) = model(local: frames(1...3))
        await model.load()
        let attach = Task { await model.attach() }
        await relay.push(LiveTranscriptFrame(seq: nil, createtime: nil, payload: Data(), rewoundTo: 2))
        await relay.push(liveFrame(decoder, 1, .userMessage("new 1")))
        await relay.push(liveFrame(decoder, 2, .userMessage("new 2")))
        try await eventually("renumbered frames shown") { userTexts(model) == ["new 1", "new 2"] }
        await relay.finish()
        await attach.value
    }

    @Test("离开对话屏期间同步落进库的帧，回来重新接上时补进转录：从转录自己读到的最新帧号接着补")
    func reattachCatchesUpFromTheTimeline() async throws {
        let (model, store, relay) = model(local: frames(1...60), machine: frames(1...60))
        await model.load()
        let first = Task { await model.attach() }
        try await eventually("attached") { await relay.attaches.count == 1 }
        await relay.finish()
        await first.value

        let away = frames(61...64)
        await store.append(away)
        await relay.append(away)
        let second = Task { await model.attach() }
        try await eventually("frames stored while away reach the timeline") { userTexts(model).count == 64 }
        #expect(userTexts(model).suffix(4) == ["m61", "m62", "m63", "m64"])
        #expect(await relay.attaches.map(\.after) == [60, 60])
        await relay.finish()
        await second.value
    }

    @Test("屏还开着、实时流断了（通道被关）：回到前台 resume 即重新接上，从转录自己的最新帧号补，刚发的那句仍在、不重不漏")
    func resumeReattachesAnOpenScreen() async throws {
        let (model, _, relay) = model(local: frames(1...3), machine: frames(1...3))
        let open = Task { await model.start() }
        try await eventually("attached") { await relay.attaches.count == 1 }
        await relay.push(liveFrame(decoder, 4, .userMessage("m4")))
        try await eventually("sent message on screen") { userTexts(model).last == "m4" }

        await relay.finish()
        await relay.append([frames(4...4)[0], stored(decoder, 5, .userMessage("m5"))])
        // 流收场之后、回到前台之前：不自己重连（通道被关可能是机器下线，没人叫就不重拨）。
        try await Task.sleep(for: .milliseconds(100))
        #expect(await relay.attaches.count == 1)

        model.resume()
        try await eventually("caught up after resume") { userTexts(model).last == "m5" }
        #expect(userTexts(model) == (1...5).map { "m\($0)" })
        #expect(await relay.attaches.map(\.after) == [3, 4])
        #expect(!open.isCancelled)

        // 还接着的时候再回前台一次（连接自己会重拨补齐）：不再叠一条 attach。
        model.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await relay.attaches.count == 2)

        open.cancel()
        await open.value
    }

    @Test("回到前台的信号赶在实时流收场被处理之前到达：不丢，流一收场就接上")
    func resumeArrivingBeforeTheStreamEndIsProcessedStillReattaches() async throws {
        let store = FakeStore(frames(1...3))
        let relay = MainActorRelay(machineFrames: frames(1...3))
        let conversation = SavedConversation(key: conversationKey, peerFingerprint: "peer-1", lifecycleState: "idle")
        let model = TranscriptModel(conversation: conversation, store: store, relay: relay, decoder: decoder, pageSize: 50)
        let open = Task { await model.start() }
        try await eventually("attached") { relay.attaches.count == 1 }
        relay.append([stored(decoder, 4, .userMessage("m4"))])

        // 服务端关掉了通道、回到前台这两件事同时发生：流已经收场，转录那一轮却还没被唤醒去处理它
        // （两句之间没有挂起点，唤醒排在后面），回前台的信号此刻到达。
        relay.finish()
        model.resume()

        try await eventually("reattached after the stream ended") { relay.attaches.count == 2 }
        #expect(relay.attaches.map(\.after) == [3, 3])
        try await eventually("caught up") { userTexts(model).last == "m4" }
        open.cancel()
        await open.value
    }

    @Test("屏已关掉（跟随的任务被取消）：流断在等 resume 时也立即收场；之后的 resume 不再接")
    func dismissedScreenDoesNotReattach() async throws {
        let (model, _, relay) = model(local: frames(1...3), machine: frames(1...3))
        let open = Task { await model.start() }
        try await eventually("attached") { await relay.attaches.count == 1 }
        await relay.finish()
        try await Task.sleep(for: .milliseconds(50))

        open.cancel()
        await open.value
        model.resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await relay.attaches.count == 1)
    }

    @Test("同一条会话开在两处：接着实时流的那一处关掉（任务取消），还开着的那一处当场接上，不等下一次回前台")
    func closingTheAttachedScreenHandsOverTheLiveStream() async throws {
        let (model, _, relay) = model(local: frames(1...3), machine: frames(1...3))
        let first = Task { await model.start() }
        try await eventually("first attached") { await relay.attaches.count == 1 }
        let second = Task { await model.start() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await relay.attaches.count == 1)

        first.cancel()
        await first.value
        try await eventually("still-open screen took over the live stream") { await relay.attaches.count == 2 }
        await relay.push(liveFrame(decoder, 4, .userMessage("m4")))
        try await eventually("live frame reaches the still-open screen") { userTexts(model).last == "m4" }

        second.cancel()
        await second.value
    }

    @Test("本地为空、历史已整段补拉回来：接上实时帧时从补拉到的最新帧号接着补，不再从头下载一遍")
    func attachAfterBackfillDoesNotRedownload() async throws {
        let (model, _, relay) = model(local: [], machine: frames(1...7), pageSize: 3)
        await model.load()
        let attach = Task { await model.attach() }
        try await eventually("attached") { await relay.attaches.count == 1 }
        #expect(await relay.attaches.map(\.after) == [7])
        await relay.finish()
        await attach.value
    }

    @Test("上滚后停止跟随，其间新增的行被计数；回到最新清零")
    func followCountsNewRows() async throws {
        let (model, _, relay) = model(local: frames(1...60))
        await model.load()
        let attach = Task { await model.attach() }
        model.userScrolledAway()
        await relay.push(liveFrame(decoder, 61, .userMessage("m61")))
        await relay.push(liveFrame(decoder, 62, .userMessage("m62")))
        try await eventually("two new rows") { model.follow.unseen == 2 }
        #expect(!model.follow.isFollowing)
        model.jumpToLatest()
        #expect(model.follow.isFollowing)
        #expect(model.follow.unseen == 0)
        await relay.finish()
        await attach.value
    }

    @Test("折叠与展开：用户点组头覆盖自动行为")
    func toggles() async {
        let local = [stored(decoder, 1, .toolCall(readUse("a"))), stored(decoder, 2, .toolCall(readUse("b"))), stored(decoder, 3, .turnDone(TurnDone()))]
        let (model, _, _) = model(local: local)
        await model.load()
        #expect(model.rows.count == 2)
        guard case .activityHeader(let header) = model.rows[1].content else { Issue.record("no header"); return }
        model.toggle(header.blockKey, current: header.expanded)
        #expect(model.rows.count == 4)
    }
}

/// 伪中继，实时流的收场由测试在主执行器上同步发出：`finish()` 与随后那一句之间没有挂起点，
/// 因此转录那一轮必定还没被唤醒去处理流的收场。
@MainActor
final class MainActorRelay: TranscriptRelay {
    private(set) var machineFrames: [TranscriptFrame]
    private(set) var attaches: [(key: ConversationKey, peer: String, after: Int64)] = []
    private var liveContinuation: AsyncStream<LiveTranscriptFrame>.Continuation?

    init(machineFrames: [TranscriptFrame] = []) {
        self.machineFrames = machineFrames.sorted { $0.seq < $1.seq }
    }

    func pull(_ key: ConversationKey, peerFingerprint: String, cursor: Int64, limit: Int) -> TranscriptPage {
        let after = machineFrames.filter { $0.seq > cursor }
        let page = Array(after.prefix(limit))
        return TranscriptPage(
            frames: page, cursor: page.last?.seq ?? cursor,
            hasMore: after.count > page.count, oldestSeq: machineFrames.first?.seq ?? 0
        )
    }

    func attach(_ key: ConversationKey, peerFingerprint: String, after: Int64) -> AsyncStream<LiveTranscriptFrame> {
        attaches.append((key, peerFingerprint, after))
        let (stream, continuation) = AsyncStream<LiveTranscriptFrame>.makeStream()
        for frame in machineFrames where frame.seq > after {
            continuation.yield(LiveTranscriptFrame(seq: frame.seq, createtime: frame.createtime, payload: frame.payload))
        }
        liveContinuation = continuation
        return stream
    }

    /// 机器上又多了几帧。
    func append(_ more: [TranscriptFrame]) { machineFrames += more }

    func finish() { liveContinuation?.finish() }
}

/// 伪中继，实时流不留缓冲：一帧只在转录正等着下一帧时才送得进去，所以 `handOff` 返回时上一帧已经合完。
@MainActor
final class HandOffRelay: TranscriptRelay {
    private let stream: AsyncStream<LiveTranscriptFrame>
    private let feed: AsyncStream<LiveTranscriptFrame>.Continuation

    init() {
        (stream, feed) = AsyncStream<LiveTranscriptFrame>.makeStream(bufferingPolicy: .bufferingNewest(0))
    }

    func pull(_ key: ConversationKey, peerFingerprint: String, cursor: Int64, limit: Int) -> TranscriptPage {
        TranscriptPage(frames: [], cursor: cursor, hasMore: false, oldestSeq: 0)
    }

    func attach(_ key: ConversationKey, peerFingerprint: String, after: Int64) -> AsyncStream<LiveTranscriptFrame> { stream }

    func handOff(_ frame: LiveTranscriptFrame) async {
        while case .dropped = feed.yield(frame) { await Task.yield() }
    }

    func finish() { feed.finish() }
}

struct FailingRelay: TranscriptRelay {
    struct Offline: Error {}
    func pull(_ key: ConversationKey, peerFingerprint: String, cursor: Int64, limit: Int) async throws -> TranscriptPage { throw Offline() }
    func attach(_ key: ConversationKey, peerFingerprint: String, after: Int64) async throws -> AsyncStream<LiveTranscriptFrame> { throw Offline() }
}
