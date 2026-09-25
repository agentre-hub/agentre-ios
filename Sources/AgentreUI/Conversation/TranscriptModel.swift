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
    /// 预览尾巴（还在流的正文与思考）。不放进合流：一篇长回复有上万片预览，每片都要把它们
    /// 从头归约一遍，一片的代价随回复变长，转录便越流越落后于机器。取代规则与合流的预览帧相同。
    @ObservationIgnored private var liveText = ""
    @ObservationIgnored private var liveThinking = ""
    /// 实时流合进来了、还没交给屏的变化。一篇长回复一秒几十片，每片都交一次，屏就每片重排一次，
    /// 排不过来的片越积越多，转录便落后于机器；所以接流时最多每 `liveInterval` 交一次。
    @ObservationIgnored private var liveDirty = false
    @ObservationIgnored private var lastLivePublish: ContinuousClock.Instant?
    @ObservationIgnored private var livePublish: Task<Void, Never>?
    static let liveInterval: Duration = .milliseconds(100)
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
    /// 机器说那一轮已在看不到的时候收了场（`reconcile`）；下一轮开始之前一直算数。
    @ObservationIgnored private var endedUnseen = false

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

    /// 重新接上承载机后，机器此刻报的会话生命周期。转录还以为一轮在跑、机器却说不在跑了：这一轮在看不到的
    /// 时候（后台、断线）收了场，收场帧不带号、补拉不回来——按一次收场落定（运行态与还挂着的前台
    /// Subagent 一并收掉），与输入区的 `reconcile` 同一口径。这一次收场总排在转录最末（随后补拉回来的
    /// 那一轮的帧仍归那一轮），下一轮开始即作废。
    public func reconcile(lifecycle: String) {
        guard document.running, lifecycle != SavedConversation.Lifecycle.running else { return }
        endedUnseen = true
        rebuild(countingNewRows: false)
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
            if absorb(frame) { publishLiveSoon() }
        }
        if liveDirty { rebuild(countingNewRows: true) }
    }

    /// 合入实时帧，当场交给屏。
    func merge(live frames: [LiveTranscriptFrame]) {
        var changed = false
        for frame in frames {
            changed = absorb(frame) || changed
        }
        if changed { rebuild(countingNewRows: true) }
    }

    /// 合入一帧实时帧，不交给屏；改变了转录时为 true。
    /// 回退标记：机器上的帧号重新起算了，手里的全是旧编号下的内容，整段丢掉，此后的帧从头来。
    private func absorb(_ frame: LiveTranscriptFrame) -> Bool {
        guard frame.rewoundTo == nil else {
            timeline = TranscriptTimeline()
            clearPreview()
            machineOldestSeq = nil
            hasOlder = false
            return true
        }
        return insert(seq: frame.seq, payload: frame.payload)
    }

    /// 离上一次交出已满 `liveInterval` 就当场交，否则到点再交；其间合进来的都并进那一次。
    private func publishLiveSoon() {
        liveDirty = true
        guard livePublish == nil else { return }
        let now = ContinuousClock.now
        guard let last = lastLivePublish, now < last + Self.liveInterval else {
            lastLivePublish = now
            rebuild(countingNewRows: true)
            return
        }
        livePublish = Task { [weak self] in
            try? await Task.sleep(until: last + Self.liveInterval)
            guard let self, !Task.isCancelled else { return }
            livePublish = nil
            lastLivePublish = .now
            if liveDirty { rebuild(countingNewRows: true) }
        }
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
        // 新的一轮开始（不是向前补回来的旧帧）：那一次按清单的收场作废。
        if case .turnStarted = decoded.event, !decoded.preview, seq.map({ $0 > (timeline.latestSeq ?? 0) }) ?? true { endedUnseen = false }
        if decoded.preview {
            // 归约只从预览帧里取正文与思考两种增量，其余的预览帧不改变转录。
            switch decoded.event {
            case .textDelta(let text): liveText += text
            case .thinkingDelta(let text): liveThinking += text
            default: return false
            }
            return true
        }
        // 比已知最新更新的持久帧、不带号的帧取代预览尾巴；向前补进来的更早帧与重复帧不取代。
        let supersedes = seq.map { $0 > (timeline.latestSeq ?? 0) } ?? true
        guard timeline.insert(seq: seq, event: decoded.event) else { return false }
        if supersedes { clearPreview() }
        return true
    }

    private func clearPreview() {
        liveText = ""
        liveThinking = ""
    }

    /// 把转录交给屏。还没交出去的实时变化先按新行交出（它们要记进「回到最新」的条数），
    /// 再做这一次不计新行的（展开、补回历史）。
    private func rebuild(countingNewRows: Bool) {
        if liveDirty, !countingNewRows { rebuild(countingNewRows: true) }
        liveDirty = false
        livePublish?.cancel()
        livePublish = nil
        var entries = timeline.entries
        if endedUnseen { entries.append(TimelineEntry(anchor: "reconciled", event: .turnDone(TurnDone()))) }
        var document = TranscriptReducer.reduce(entries, initiallyRunning: conversation.lifecycleState == SavedConversation.Lifecycle.running)
        document.liveText = liveText
        document.liveThinking = liveThinking
        self.document = document
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
