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

    /// 读历史并接上实时帧（视图出现时调用，重复调用无副作用）。
    public func start() async {
        await load()
        await attach()
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

    /// 接上实时帧，直到通道关闭。
    public func attach() async {
        guard !attached else { return }
        attached = true
        defer { attached = false }
        guard let stream = try? await relay.attach(conversation.key, peerFingerprint: conversation.peerFingerprint) else { return }
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
