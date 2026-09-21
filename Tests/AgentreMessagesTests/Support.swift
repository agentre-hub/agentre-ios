import AgentreDomain
import AgentreStore
import AgentreWire
import Foundation
import Testing

let machine = "machine-1"
let storeNow: Int64 = 1_900_000_000_000

func key(_ id: String, machine: String = machine) -> ConversationKey {
    ConversationKey(machineFingerprint: machine, conversationID: id)
}

/// 一个真实的临时目录，测试结束时删掉。
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "AgentreMessagesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

func openStore(_ directory: TemporaryDirectory, now: Int64 = storeNow) throws -> LocalConversationStore {
    try LocalConversationStore(directory: directory.url, now: { now })
}

func summary(
    _ conversationID: String, title: String = "", lifecycle: String = "idle", waiting: Bool = false, lastMessageAt: Int64 = 1_000
) -> Agentre_Wire_SessionSummary {
    var s = Agentre_Wire_SessionSummary()
    s.conversationID = conversationID
    s.title = title
    s.lifecycleState = lifecycle
    s.waitingForInput = waiting
    s.lastMessageAt = lastMessageAt
    return s
}

// MARK: 帧

func runtimeEvent(_ conversationID: String, seq: Int64 = 0, _ fill: (inout Agentre_Wire_RuntimeEventNotification) -> Void) -> Agentre_Wire_RpcNotification {
    var e = Agentre_Wire_RuntimeEventNotification()
    e.conversationID = conversationID
    e.seq = seq
    fill(&e)
    var n = Agentre_Wire_RpcNotification()
    n.runtimeEvent = e
    return n
}

func text(_ conversationID: String, _ value: String) -> Agentre_Wire_RpcNotification {
    runtimeEvent(conversationID) { var d = Agentre_Wire_TextDelta(); d.text = value; $0.textDelta = d }
}

func userMessage(_ conversationID: String, _ value: String) -> Agentre_Wire_RpcNotification {
    runtimeEvent(conversationID) { var m = Agentre_Wire_UserMessage(); m.text = value; $0.userMessage = m }
}

func permissionRequest(_ conversationID: String, id: String, tool: String = "Bash", input: String = #"{"command":"rm -rf build"}"#) -> Agentre_Wire_RpcNotification {
    runtimeEvent(conversationID) {
        var r = Agentre_Wire_ToolPermissionRequest()
        r.requestID = id
        r.toolName = tool
        r.input = Data(input.utf8)
        $0.toolPermissionRequest = r
    }
}

func permissionResolved(_ conversationID: String, id: String) -> Agentre_Wire_RpcNotification {
    runtimeEvent(conversationID) {
        var r = Agentre_Wire_ToolPermissionResolved()
        r.requestID = id
        r.allowed = true
        $0.toolPermissionResolved = r
    }
}

func askRequest(_ conversationID: String, id: String, question: String) -> Agentre_Wire_RpcNotification {
    runtimeEvent(conversationID) {
        var q = Agentre_Wire_AskQuestion()
        q.question = question
        var r = Agentre_Wire_UserAskRequest()
        r.requestID = id
        r.questions = [q]
        $0.userAskRequest = r
    }
}

func askResolved(_ conversationID: String, id: String) -> Agentre_Wire_RpcNotification {
    runtimeEvent(conversationID) {
        var r = Agentre_Wire_UserAskResolved()
        r.requestID = id
        $0.userAskResolved = r
    }
}

func turnStarted(_ conversationID: String) -> Agentre_Wire_RpcNotification {
    var t = Agentre_Wire_TurnStartedNotification()
    t.conversationID = conversationID
    var n = Agentre_Wire_RpcNotification()
    n.turnStarted = t
    return n
}

func autonomousTurnStarted(_ conversationID: String) -> Agentre_Wire_RpcNotification {
    var t = Agentre_Wire_AutonomousTurnStartedNotification()
    t.conversationID = conversationID
    var n = Agentre_Wire_RpcNotification()
    n.autonomousTurnStarted = t
    return n
}

func runResultDone(_ conversationID: String, stopError: String = "", code: Int32 = 0, autonomous: Bool = false) -> Agentre_Wire_RpcNotification {
    var d = Agentre_Wire_RunResultDoneNotification()
    d.conversationID = conversationID
    d.stopErrorMessage = stopError
    d.stopErrorCode = code
    var n = Agentre_Wire_RpcNotification()
    if autonomous { n.autonomousTurnDone = d } else { n.runResultDone = d }
    return n
}

/// 实时到达的一帧（载体上没有发生时刻）。轮次边界帧线上不带号：`seq` 缺省即不带。
func live(_ payload: Agentre_Wire_RpcNotification, seq: Int64? = nil, conversationID: String = "conv-1") -> IncomingFrame {
    IncomingFrame(conversationID: conversationID, seq: seq, createtime: nil, payload: payload)
}

/// 补齐拉回的一帧（载体上带着源端的发生时刻）。
func pulled(_ payload: Agentre_Wire_RpcNotification, seq: Int64, conversationID: String = "conv-1") -> IncomingFrame {
    IncomingFrame(conversationID: conversationID, seq: seq, createtime: 500, payload: payload)
}

// MARK: 伪仓储

/// 注入视图模型的伪本地库：内容由测试摆好；`markRead` 可以挂住或失败，以验乐观改写。
actor FakeConversationStore: ConversationStore {
    private var rows: [SavedConversation]
    private var observers: [AsyncStream<Void>.Continuation] = []
    private var readGate: CheckedContinuation<Void, Never>?
    var holdReads = false
    var failReads = false
    private(set) var readRequests: [ConversationKey] = []

    init(_ rows: [SavedConversation]) { self.rows = rows }

    func set(_ rows: [SavedConversation]) {
        self.rows = rows
        for observer in observers { observer.yield() }
    }

    func configure(holdReads: Bool = false, failReads: Bool = false) {
        self.holdReads = holdReads
        self.failReads = failReads
    }

    func releaseRead() {
        readGate?.resume()
        readGate = nil
    }

    var isHoldingRead: Bool { readGate != nil }
    var observerCount: Int { observers.count }

    func conversations() -> [SavedConversation] { rows }
    func conversation(_ key: ConversationKey) -> SavedConversation? { rows.first { $0.key == key } }
    func transcript(_ key: ConversationKey) -> [TranscriptFrame] { [] }
    func latestSeq(_ key: ConversationKey) -> Int64 { 0 }

    func markRead(_ key: ConversationKey) async throws {
        readRequests.append(key)
        if holdReads { await withCheckedContinuation { readGate = $0 } }
        if failReads { throw CancellationError() }
        if let index = rows.firstIndex(where: { $0.key == key }) { rows[index].readMarker = rows[index].lastMessageAt }
        for observer in observers { observer.yield() }
    }

    func delete(_ key: ConversationKey) { rows.removeAll { $0.key == key } }
    func removeAll() { rows = [] }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers.append(continuation)
        return stream
    }
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
