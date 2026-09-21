import AgentreDomain
@testable import AgentreUI
import Foundation
import SwiftUI
import Testing

let conversationKey = ConversationKey(machineFingerprint: "machine-1", conversationID: "conv-1")
let savedConversation = SavedConversation(key: conversationKey, peerFingerprint: "peer-1", cwd: "/Users/dev/agentre", lifecycleState: "running")

func permission(_ id: String = "p1", tool: String = "Bash", input: [String: JSONValue]? = ["command": "pnpm test"], resolved: Bool = false, allowed: Bool = false) -> PermissionRequest {
    var request = PermissionRequest(requestID: id, toolCallID: "t-\(id)", toolName: tool, input: input)
    request.resolved = resolved
    request.allowed = allowed
    return request
}

func question(_ id: String = "q1", _ questions: [String] = ["用哪个分支？"], answered: Bool = false) -> QuestionRequest {
    var request = QuestionRequest(requestID: id, toolCallID: "t-\(id)", questions: questions)
    request.answered = answered
    return request
}

/// 伪作答端口：记下每次作答；`failing` 为真时抛错；`gate` 在时作答挂起直到放行。
actor FakeAnswering: ApprovalAnswering {
    struct Failure: Error {}

    private(set) var permissions: [ToolPermissionReply] = []
    private(set) var answers: [QuestionReply] = []
    var failing = false
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false

    func setFailing(_ value: Bool) { failing = value }
    func hold() { holding = true }
    func release() {
        holding = false
        gate?.resume()
        gate = nil
    }

    func submitToolPermission(_ reply: ToolPermissionReply) async throws {
        permissions.append(reply)
        try await pass()
    }

    func submitAnswer(_ reply: QuestionReply) async throws {
        answers.append(reply)
        try await pass()
    }

    private func pass() async throws {
        if holding { await withCheckedContinuation { gate = $0 } }
        if failing { throw Failure() }
    }
}

/// 伪解码器：载荷就是一个登记号，登记号 → 解码结果由测试摆好。
final class FakeDecoder: TranscriptPayloadDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Data: DecodedNotification] = [:]
    private var next = 0

    func payload(_ event: TranscriptEvent) -> Data {
        lock.lock(); defer { lock.unlock() }
        next += 1
        let data = Data("p\(next)".utf8)
        table[data] = DecodedNotification(event: event)
        return data
    }

    func decode(_ payload: Data) -> DecodedNotification? {
        lock.lock(); defer { lock.unlock() }
        return table[payload]
    }
}

actor FakeStore: ConversationStore {
    let frames: [TranscriptFrame]
    init(_ frames: [TranscriptFrame]) { self.frames = frames }
    func conversations() -> [SavedConversation] { [savedConversation] }
    func conversation(_ key: ConversationKey) -> SavedConversation? { savedConversation }
    func transcript(_ key: ConversationKey) -> [TranscriptFrame] { frames }
    func latestSeq(_ key: ConversationKey) -> Int64 { frames.map(\.seq).max() ?? 0 }
    func markRead(_ key: ConversationKey) {}
    func delete(_ key: ConversationKey) {}
    func removeAll() {}
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

/// 伪中继：机器上没有更多帧，实时流不来东西。
struct FakeRelay: TranscriptRelay {
    func pull(_ key: ConversationKey, peerFingerprint: String, cursor: Int64, limit: Int) -> TranscriptPage {
        TranscriptPage(frames: [], cursor: cursor, hasMore: false, oldestSeq: 0)
    }

    func attach(_ key: ConversationKey, peerFingerprint: String) -> AsyncStream<LiveTranscriptFrame> {
        AsyncStream { _ in }
    }
}

/// 一段只有一轮的转录：用户一句话，agent 停在一张卡片上。
@MainActor
func transcript(ending events: [TranscriptEvent]) async -> TranscriptModel {
    let decoder = FakeDecoder()
    let all: [TranscriptEvent] = [.userMessage("跑一下测试"), .turnStarted, .textDelta("需要你批准。")] + events
    let frames = all.enumerated().map { TranscriptFrame(seq: Int64($0.offset + 1), createtime: 1_000, payload: decoder.payload($0.element)) }
    let model = TranscriptModel(conversation: savedConversation, store: FakeStore(frames), relay: FakeRelay(), decoder: decoder, pageSize: 10)
    await model.load()
    return model
}

/// 把卡片接在转录的插入点上。
@MainActor
func screen(_ transcript: TranscriptModel, cards: ApprovalCardsModel, language: String) -> some View {
    TranscriptView(model: transcript, agentName: "Claude Code") { ApprovalCard($0, model: cards) }
        .environment(\.locale, Locale(identifier: language))
}

/// 字符串表里某个键在某种语言下的译文。
func text(_ key: String, _ language: String) throws -> String {
    let path = try #require(AgentreUIResources.bundle.path(forResource: language, ofType: "lproj"))
    let bundle = try #require(Bundle(path: path))
    let value = bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Cards")
    #expect(value != "⟨missing⟩", "\(key) [\(language)]")
    return value
}

/// 两块命中区之间的空隙（取横竖两向里较大的那个）：大于零即互不相接。
func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    max(b.minX - a.maxX, a.minX - b.maxX, b.minY - a.maxY, a.minY - b.maxY)
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
