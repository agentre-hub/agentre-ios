import AgentreDomain
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

struct FailingRelay: TranscriptRelay {
    struct Offline: Error {}
    func pull(_ key: ConversationKey, peerFingerprint: String, cursor: Int64, limit: Int) async throws -> TranscriptPage { throw Offline() }
    func attach(_ key: ConversationKey, peerFingerprint: String, after: Int64) async throws -> AsyncStream<LiveTranscriptFrame> { throw Offline() }
}
