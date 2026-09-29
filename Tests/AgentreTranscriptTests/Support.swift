import AgentreDomain
import Foundation
import Testing

// MARK: 工具步骤

func use(
    _ id: String,
    _ name: String = "Bash",
    input: [String: JSONValue]? = ["command": "echo hi"],
    canonical: Canonical? = nil,
    parent: String? = nil,
    subagent: SubagentState? = nil
) -> ToolUse {
    ToolUse(id: id, name: name, input: input, canonical: canonical, parentID: parent, subagent: subagent)
}

func readUse(_ id: String, path: String = "/repo/chat.go") -> ToolUse {
    use(id, "Read", input: ["path": .string(path)])
}

func result(_ id: String, _ text: String = "ok", isError: Bool = false) -> ToolResult {
    ToolResult(toolCallID: id, text: text, isError: isError)
}

func toolStep(_ key: String, _ tool: ToolUse, _ result: ToolResult? = nil) -> ActivityStep {
    .tool(key: key, use: tool, result: result)
}

func thinkingStep(_ key: String, _ text: String) -> ActivityStep {
    .thinking(key: key, text: text)
}

func editCanonical(_ files: [(path: String, plus: Int, minus: Int)]) -> Canonical {
    Canonical(kind: Canonical.Kind.fileEdit, fields: [
        "files": .array(files.map { .object(["path": .string($0.path), "plus": .number(Double($0.plus)), "minus": .number(Double($0.minus))]) }),
    ])
}

func backgroundUse(_ id: String, status: String?) -> ToolUse {
    use(id, input: ["command": "pnpm dev", "run_in_background": true], subagent: SubagentState(taskID: "bg-\(id)", status: status ?? ""))
}

/// 一轮长活动：每 5 步夹一条失败的命令，其余是只读探查（与宿主 block.test 的 manySteps 同形）。
func manySteps(_ n: Int) -> [ActivityStep] {
    (0..<n).map { i in
        i % 5 == 4
            ? toolStep("many-\(i)", use("many-\(i)", input: ["command": .string("pnpm run step-\(i)")]), result("many-\(i)", #"{"exitCode":1,"output":"boom"}"#, isError: true))
            : toolStep("many-\(i)", readUse("many-\(i)", path: "/repo/f-\(i).go"), result("many-\(i)", "line \(i)"))
    }
}

// MARK: 帧

/// 伪解码器：载荷就是一个登记号，登记号 → 解码结果由测试摆好。
/// 真实解码（wire → 领域）归认得 wire 的那一层（任务 12）。
final class FakeDecoder: TranscriptPayloadDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Data: DecodedNotification] = [:]
    private var next = 0

    func payload(_ event: TranscriptEvent, preview: Bool = false) -> Data {
        lock.lock(); defer { lock.unlock() }
        next += 1
        let data = Data("p\(next)".utf8)
        table[data] = DecodedNotification(preview: preview, event: event)
        return data
    }

    func decode(_ payload: Data) -> DecodedNotification? {
        lock.lock(); defer { lock.unlock() }
        return table[payload]
    }
}

func stored(_ decoder: FakeDecoder, _ seq: Int64, _ event: TranscriptEvent) -> TranscriptFrame {
    TranscriptFrame(seq: seq, createtime: 1_000 + seq, payload: decoder.payload(event))
}

func liveFrame(_ decoder: FakeDecoder, _ seq: Int64?, _ event: TranscriptEvent, preview: Bool = false) -> LiveTranscriptFrame {
    LiveTranscriptFrame(seq: seq, createtime: nil, payload: decoder.payload(event, preview: preview))
}

/// 按真实 agentred 的形状把一篇回复切成预览增量：dev 上一篇 17949 字的回复是 795 片思考、11077 片正文
/// （平均每片一两个字，fanout 日志的 eventKinds）。先思考，再正文一片一两个字交替。
func realisticReply(_ text: String, thinkingDeltas: Int = 795) -> [TranscriptEvent] {
    var events = (0..<thinkingDeltas).map { _ in TranscriptEvent.thinkingDelta("想") }
    let characters = Array(text)
    var index = 0
    while index < characters.count {
        let size = events.count.isMultiple(of: 2) ? 1 : 2
        events.append(.textDelta(String(characters[index..<min(index + size, characters.count)])))
        index += size
    }
    return events
}

/// 除日期胶囊之外的行：胶囊随帧的时刻插，与这些用例要数的内容无关。
func contentRows(_ rows: [TranscriptRow]) -> [TranscriptRow] {
    rows.filter { if case .day = $0.content { false } else { true } }
}

let machine = "machine-1"
let conversationKey = ConversationKey(machineFingerprint: machine, conversationID: "conv-1")

// MARK: 伪端口

/// 伪本地库：只摆一条会话的帧。
actor FakeStore: ConversationStore {
    var frames: [TranscriptFrame]
    let summary: SavedConversation
    private(set) var transcriptReads = 0

    init(_ frames: [TranscriptFrame], summary: SavedConversation = SavedConversation(key: conversationKey, peerFingerprint: "peer-1")) {
        self.frames = frames
        self.summary = summary
    }

    func conversations() -> [SavedConversation] { [summary] }
    func conversation(_ key: ConversationKey) -> SavedConversation? { key == summary.key ? summary : nil }
    func transcript(_ key: ConversationKey) -> [TranscriptFrame] {
        transcriptReads += 1
        return key == summary.key ? frames.sorted { $0.seq < $1.seq } : []
    }
    func latestSeq(_ key: ConversationKey) -> Int64 { frames.map(\.seq).max() ?? 0 }
    /// 屏外的同步把帧落进了库。
    func append(_ more: [TranscriptFrame]) { frames += more }
    func markRead(_ key: ConversationKey) {}
    func delete(_ key: ConversationKey) {}
    func removeAll() {}
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

/// 伪中继：pull 按游标从一段「机器上的全部帧」里切页（与 agentred 的 ListSince 同义：
/// 返回 seq > cursor 的升序帧，最多 limit 条），attach 先补齐游标之后的帧、再交出测试可推帧的实时流。
actor FakeRelay: TranscriptRelay {
    private(set) var machineFrames: [TranscriptFrame]
    private(set) var pulls: [(cursor: Int64, limit: Int, peer: String)] = []
    private(set) var attaches: [(key: ConversationKey, peer: String, after: Int64)] = []
    private var liveContinuation: AsyncStream<LiveTranscriptFrame>.Continuation?
    private var pendingLive: [LiveTranscriptFrame] = []

    init(machineFrames: [TranscriptFrame] = []) {
        self.machineFrames = machineFrames.sorted { $0.seq < $1.seq }
    }

    func pull(_ key: ConversationKey, peerFingerprint: String, cursor: Int64, limit: Int) -> TranscriptPage {
        pulls.append((cursor, limit, peerFingerprint))
        let after = machineFrames.filter { $0.seq > cursor }
        let page = Array(after.prefix(limit))
        return TranscriptPage(
            frames: page,
            cursor: page.last?.seq ?? cursor,
            hasMore: after.count > page.count,
            oldestSeq: machineFrames.first?.seq ?? 0
        )
    }

    /// 与通道的 attach 同义：先补齐机器上 seq 大于 `after` 的帧（带源端 createtime），再接实时帧。
    func attach(_ key: ConversationKey, peerFingerprint: String, after: Int64) -> AsyncStream<LiveTranscriptFrame> {
        attaches.append((key, peerFingerprint, after))
        let (stream, continuation) = AsyncStream<LiveTranscriptFrame>.makeStream()
        for frame in machineFrames where frame.seq > after {
            continuation.yield(LiveTranscriptFrame(seq: frame.seq, createtime: frame.createtime, payload: frame.payload))
        }
        for frame in pendingLive { continuation.yield(frame) }
        pendingLive = []
        liveContinuation = continuation
        return stream
    }

    func push(_ frame: LiveTranscriptFrame) {
        if let liveContinuation { liveContinuation.yield(frame) } else { pendingLive.append(frame) }
    }

    func finish() { liveContinuation?.finish() }

    /// 机器上又多了几帧。
    func append(_ more: [TranscriptFrame]) { machineFrames += more }
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
