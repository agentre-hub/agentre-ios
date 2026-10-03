import AgentreDomain
import AgentreStore
import AgentreWire
import Foundation
import Testing

let machineFingerprint = "fp-mac"

func onlineMachine(_ fingerprint: String = machineFingerprint) -> Machine {
    Machine(id: 1, fingerprint: fingerprint, name: "studio-mac", kind: "desktop", online: true, lastSeenAt: 1_900_000_000_000)
}

func offlineMachine(_ fingerprint: String = machineFingerprint) -> Machine {
    Machine(id: 1, fingerprint: fingerprint, name: "studio-mac", kind: "desktop", online: false, lastSeenAt: 1_800_000_000_000)
}

func session(
    _ id: String, title: String = "", peer: String = "", cwd: String = "", lifecycle: String = "idle", waiting: Bool = false, at: Int64 = 1_000
) -> MachineSession {
    MachineSession(conversationID: id, peerFingerprint: peer, title: title, cwd: cwd, lifecycleState: lifecycle, waitingForInput: waiting, lastMessageAt: at)
}

func key(_ id: String, machine: String = machineFingerprint) -> ConversationKey {
    ConversationKey(machineFingerprint: machine, conversationID: id)
}

// MARK: 伪中继：会话清单与计数

/// 机器一端的伪清单：新到旧的会话按标题（大小写不敏感子串）收窄，游标是下一页起点的序号。
actor FakeSessionSource: MachineSessionSource {
    struct Request: Equatable {
        let machine: String
        let keyword: String
        let cursor: String
        let limit: Int
    }

    var all: [MachineSession]
    var counts = MachineSessionCounts(total: 0, running: 0, waiting: 0)
    /// 按机器指纹分开的计数：名册屏同时问好几台机器，各自要各自的答复。没配的那台落回 `counts`。
    var countsByMachine: [String: MachineSessionCounts] = [:]
    var failing = false
    /// 请求随所在任务被取消而收场（中继调用对取消的应答）。
    var cancelling = false
    private(set) var requests: [Request] = []
    private(set) var countRequests = 0
    /// 挂住某个关键词的请求，直到 `release` 为止。
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    private var holdKeywords: Set<String> = []

    init(_ all: [MachineSession]) { self.all = all }

    func setCounts(_ counts: MachineSessionCounts) { self.counts = counts }
    func setCounts(_ counts: MachineSessionCounts, for machine: String) { countsByMachine[machine] = counts }
    func setFailing(_ failing: Bool) { self.failing = failing }
    func setCancelling(_ cancelling: Bool) { self.cancelling = cancelling }
    func setSessions(_ all: [MachineSession]) { self.all = all }
    func hold(_ keyword: String) { holdKeywords.insert(keyword) }
    func isHolding(_ keyword: String) -> Bool { held[keyword] != nil }
    func release(_ keyword: String) {
        holdKeywords.remove(keyword)
        held.removeValue(forKey: keyword)?.resume()
    }

    func sessions(on machine: String, keyword: String, cursor: String, limit: Int) async throws -> MachineSessionPage {
        requests.append(Request(machine: machine, keyword: keyword, cursor: cursor, limit: limit))
        if holdKeywords.contains(keyword) { await withCheckedContinuation { held[keyword] = $0 } }
        if cancelling { throw CancellationError() }
        if failing { throw URLError(.timedOut) }
        let matching = keyword.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
        let start = Int(cursor) ?? 0
        let end = min(start + limit, matching.count)
        let page = Array(matching[min(start, end)..<end])
        let more = end < matching.count
        return MachineSessionPage(sessions: page, cursor: more ? String(end) : "", hasMore: more, total: Int64(matching.count))
    }

    /// 只问不到这几台的计数（其余照答）。
    var failingMachines: Set<String> = []
    func setFailing(machines: Set<String>) { failingMachines = machines }
    /// 挂住下一次计数请求，直到 `releaseCounts`。
    private var holdNextCounts = false
    private var heldCounts: CheckedContinuation<Void, Never>?
    func holdNextCountRequest() { holdNextCounts = true }
    var isHoldingCounts: Bool { heldCounts != nil }
    func releaseCounts() { heldCounts?.resume(); heldCounts = nil }

    func counts(on machine: String) async throws -> MachineSessionCounts {
        countRequests += 1
        // 挂住时记下的是请求那一刻的答案：晚到的是「那时」的计数。
        let answer = countsByMachine[machine] ?? counts
        if holdNextCounts {
            holdNextCounts = false
            await withCheckedContinuation { heldCounts = $0 }
        }
        if cancelling { throw CancellationError() }
        if failing || failingMachines.contains(machine) { throw URLError(.timedOut) }
        return answer
    }
}

// MARK: 伪中继：attach / pull

/// 机器一端的伪转录：每条会话一串持久帧，按游标分批给出。
actor FakeTransfer: MachineSessionTransfer {
    var transcripts: [String: [PulledFrame]]
    let batch: Int
    var failPullAfterFirstBatch = false
    var failAttach = false
    private(set) var attaches: [String] = []
    private(set) var pulls: [Int64] = []

    init(_ transcripts: [String: [PulledFrame]] = [:], batch: Int = 2) {
        self.transcripts = transcripts
        self.batch = batch
    }

    func configure(failAttach: Bool = false, failPullAfterFirstBatch: Bool = false) {
        self.failAttach = failAttach
        self.failPullAfterFirstBatch = failPullAfterFirstBatch
    }

    func attach(conversationID: String, peerFingerprint: String, on machine: String) async throws -> Int64? {
        attaches.append(conversationID)
        if failAttach { throw CancellationError() }
        return transcripts[conversationID]?.last?.seq ?? 0
    }

    func pull(conversationID: String, peerFingerprint: String, after cursor: Int64, on machine: String) async throws -> PulledFrames {
        if failPullAfterFirstBatch, !pulls.isEmpty { throw CancellationError() }
        pulls.append(cursor)
        let rest = (transcripts[conversationID] ?? []).filter { $0.seq > cursor }
        let page = Array(rest.prefix(batch))
        return PulledFrames(frames: page, cursor: page.last?.seq ?? cursor, hasMore: rest.count > page.count)
    }
}

// MARK: 伪本地库

/// 内存里的本地库，写入一侧照 LocalConversationStore 的规矩：不认识的会话一帧不落，帧按 seq 去重。
actor FakeSavingStore: ConversationSaving {
    private var rows: [SavedConversation] = []
    private(set) var frames: [ConversationKey: [PulledFrame]] = [:]
    private var observers: [AsyncStream<Void>.Continuation] = []
    var observerCount: Int { observers.count }

    init(saved: [ConversationKey] = []) {
        rows = saved.map { SavedConversation(key: $0) }
    }

    func save(_ session: MachineSession, via machine: String) -> ConversationKey {
        let key = ConversationKey(machineFingerprint: session.peerFingerprint.isEmpty ? machine : session.peerFingerprint, conversationID: session.conversationID)
        if !rows.contains(where: { $0.key == key }) { rows.append(SavedConversation(key: key, title: session.title)) }
        notify()
        return key
    }

    func record(_ incoming: [PulledFrame], into key: ConversationKey) {
        guard rows.contains(where: { $0.key == key }) else { return }
        var existing = frames[key] ?? []
        for frame in incoming where !existing.contains(where: { $0.seq == frame.seq }) { existing.append(frame) }
        frames[key] = existing.sorted { $0.seq < $1.seq }
        notify()
    }

    func conversations() -> [SavedConversation] { rows }
    func conversation(_ key: ConversationKey) -> SavedConversation? { rows.first { $0.key == key } }
    func transcript(_ key: ConversationKey) -> [TranscriptFrame] {
        (frames[key] ?? []).map { TranscriptFrame(seq: $0.seq, createtime: $0.createtime, payload: $0.payload) }
    }
    func latestSeq(_ key: ConversationKey) -> Int64 { frames[key]?.last?.seq ?? 0 }
    func markRead(_ key: ConversationKey) {}
    func delete(_ key: ConversationKey) {
        rows.removeAll { $0.key == key }
        frames[key] = nil
        notify()
    }
    func removeAll() {
        rows = []
        frames = [:]
        notify()
    }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers.append(continuation)
        return stream
    }

    private func notify() {
        for observer in observers { observer.yield() }
    }
}

func frames(_ seqs: ClosedRange<Int64>) -> [PulledFrame] {
    seqs.map { PulledFrame(seq: $0, createtime: 100 + $0, payload: Data([UInt8($0)])) }
}

/// 等一个条件成立（真实时间上限 3 秒）。
@MainActor
func eventually(_ what: String = "condition", sourceLocation: SourceLocation = #_sourceLocation, _ probe: @MainActor () async -> Bool) async throws {
    for _ in 0..<3000 {
        if await probe() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    throw CancellationError()
}
