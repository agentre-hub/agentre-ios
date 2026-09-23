import AgentreDomain
import Foundation
import Observation

/// 对话屏的转录。历史先读本地库；本地不足一页、或用户翻到顶时，经中继向承载会话的机器
/// 按 seq 向后补拉（不读服务端的转录端点）；实时帧与两者按 seq 合流。
@MainActor
@Observable
public final class TranscriptModel {
    public let conversation: SavedConversation
    public private(set) var rows: [TranscriptRow] = []
    public private(set) var document = TranscriptDocument()
    public private(set) var follow = TranscriptFollow()
    /// 机器上可能还有比已读到的更早的帧。
    public private(set) var hasOlder = false

    /// 上下文用量；窗口不为正时为 nil（整块不渲染）。
    public var contextUsage: ContextUsage? { document.contextUsage }

    @ObservationIgnored private let store: any ConversationStore
    @ObservationIgnored private let relay: any TranscriptRelay
    @ObservationIgnored private let decoder: any TranscriptPayloadDecoding
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var timeline = TranscriptTimeline()
    @ObservationIgnored private var disclosure = TranscriptDisclosure()
    /// 机器报的最早帧号；还没问过时为 nil。
    @ObservationIgnored private var machineOldestSeq: Int64?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var pulling = false
    /// 实时流已收场、正等着 `resume()` 的各处跟随（同一条会话可以同时开在两个标签里）。
    @ObservationIgnored private var waiting: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// 回到前台的次数。每一轮实时流开始前记下它，收场时再比一次：这一轮期间到过的信号照样算数，
    /// 不会因为流的收场还没被唤醒处理就丢掉。
    @ObservationIgnored private var resumeCount = 0

    /// - Parameters:
    ///   - conversation: 本地库里的会话；它的键给出承载机器，`peerFingerprint` 原样带给 pull / attach。
    ///   - pageSize: 本地少于这么多帧即向机器补一页；向后翻页也按这个大小。
    public init(
        conversation: SavedConversation,
        store: any ConversationStore,
        relay: any TranscriptRelay,
        decoder: any TranscriptPayloadDecoding,
        pageSize: Int = 50
    ) {
        self.conversation = conversation
        self.store = store
        self.relay = relay
        self.decoder = decoder
        self.pageSize = max(1, pageSize)
    }

    /// 读历史并跟随实时帧，直到所在任务被取消（视图出现时调用，随视图消失而取消）。
    /// 实时流收场（服务端关了通道、机器下线）后不自己重拨，等 `resume()` 再从转录的最新帧号接上。
    public func start() async {
        await load()
        while !Task.isCancelled {
            let seen = resumeCount
            await attach()
            await waitForResume(since: seen)
        }
    }

    /// 回到前台、网络恢复：屏还开着而实时流已收场时重新接上；流还接着、或屏已关掉时什么也不做。
    ///
    /// 信号在流收场的同一刻到达（通道已关，接流的那一轮还没被唤醒读到收场）也不丢：那一轮
    /// 一醒来就发现信号变了，当场重新接上，而不是停在那里等下一次回前台。
    public func resume() {
        resumeCount += 1
        for signal in waiting.values { signal.yield() }
    }

    /// 读本地库；不足一页时向机器补一页。只读一次。
    public func load() async {
        guard !loaded else { return }
        loaded = true
        let frames = (try? await store.transcript(conversation.key)) ?? []
        for frame in frames {
            insert(seq: frame.seq, payload: frame.payload)
        }
        hasOlder = timeline.oldestSeq.map { $0 > 1 } ?? true
        rebuild(countingNewRows: false)
        if timeline.count < pageSize {
            await pullOlder()
        }
    }

    /// 用户翻到了顶：再往前补一页。
    public func loadOlder() async {
        guard loaded, hasOlder else { return }
        await pullOlder()
    }

    /// 接上实时帧，直到通道关闭。从转录自己读到的最新帧号接着补：离开屏幕期间同步落进本地库的帧
    /// 不在转录里，按库的游标补会把它们漏掉；刚整段补拉回来的历史也不必再下载一遍。
    public func attach() async {
        guard !attached else { return }
        attached = true
        defer {
            attached = false
            // 接着流的这一处关掉了（同一条会话还开在另一个标签里）：把流交给还在等的那一处，不等下一次回前台。
            if Task.isCancelled { resume() }
        }
        guard let stream = try? await relay.attach(conversation.key, peerFingerprint: conversation.peerFingerprint, after: timeline.latestSeq ?? 0) else { return }
        for await frame in stream {
            merge(live: [frame])
        }
    }

    /// 合入实时帧。
    func merge(live frames: [LiveTranscriptFrame]) {
        var changed = false
        for frame in frames {
            changed = insert(seq: frame.seq, payload: frame.payload) || changed
        }
        if changed { rebuild(countingNewRows: true) }
    }

    // MARK: 交互

    public func toggle(_ key: String, current: Bool) {
        disclosure.toggle(key, current: current)
        rebuild(countingNewRows: false)
    }

    public func showAll(_ key: String) {
        disclosure.showAll(key)
        rebuild(countingNewRows: false)
    }

    public func userScrolledAway() { follow.userScrolledAway() }
    public func reachedBottom() { follow.reachedBottom() }
    public func jumpToLatest() { follow.jumpToLatest() }

    // MARK: 内部

    /// 等下一次 `resume()`；这一轮实时流期间已经到过信号（`seen` 之后）即当场返回，
    /// 所在任务被取消也返回。
    private func waitForResume(since seen: Int) async {
        guard !Task.isCancelled, resumeCount == seen else { return }
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        waiting[token] = continuation
        for await _ in signals { break }
        continuation.finish()
        waiting[token] = nil
    }

    /// 从本地已有的最早帧往前补：游标取「最早帧之前一页」，但不早于机器报的最早帧；
    /// 按 has_more 续拉，只收比本地最早帧更早的。本地为空时从头拉到机器说没有更多为止。
    private func pullOlder() async {
        guard !pulling else { return }
        pulling = true
        defer { pulling = false }
        let before = timeline.oldestSeq
        var cursor: Int64 = 0
        if let before {
            let floor = (machineOldestSeq ?? 1) - 1
            cursor = max(0, max(floor, before - 1 - Int64(pageSize)))
        }
        var collected: [TranscriptFrame] = []
        do {
            while true {
                let page = try await relay.pull(conversation.key, peerFingerprint: conversation.peerFingerprint, cursor: cursor, limit: pageSize)
                if page.oldestSeq > 0 { machineOldestSeq = page.oldestSeq }
                collected += page.frames.filter { frame in before.map { frame.seq < $0 } ?? true }
                guard page.hasMore, !page.frames.isEmpty, page.cursor > cursor else { break }
                if let before, page.cursor >= before - 1 { break }
                cursor = page.cursor
            }
        } catch {
            // 离线：本地内容照常可读，下次翻到顶再试。
            merge(older: collected)
            return
        }
        merge(older: collected)
        if let machineOldestSeq {
            hasOlder = (timeline.oldestSeq ?? machineOldestSeq) > machineOldestSeq
        } else {
            hasOlder = false
        }
    }

    private func merge(older frames: [TranscriptFrame]) {
        var changed = false
        for frame in frames {
            changed = insert(seq: frame.seq, payload: frame.payload) || changed
        }
        if changed { rebuild(countingNewRows: false) }
    }

    @discardableResult
    private func insert(seq: Int64?, payload: Data) -> Bool {
        guard let decoded = decoder.decode(payload) else { return false }
        if decoded.preview {
            return timeline.insert(seq: nil, event: decoded.event, preview: true)
        }
        return timeline.insert(seq: seq, event: decoded.event)
    }

    private func rebuild(countingNewRows: Bool) {
        document = TranscriptReducer.reduce(timeline.entries, initiallyRunning: conversation.lifecycleState == SavedConversation.Lifecycle.running)
        let previous = countingNewRows ? Set(rows.map(\.id)) : []
        rows = TranscriptRows.build(document, disclosure: disclosure, cwd: conversation.cwd)
        if countingNewRows {
            follow.appended(rows.count { row in
                if case .agentHeader = row.content { return false }
                return !previous.contains(row.id)
            })
        }
    }
}
