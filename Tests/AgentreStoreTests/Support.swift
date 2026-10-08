import AgentreDomain
import AgentreRelay
import AgentreStore
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

/// 等一个条件成立（真实时间上限 3 秒）。只用来等并发的那一侧走到某一步，判据仍由断言给出。
func eventually<T>(
    _ what: String = "condition",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ probe: () async throws -> T?
) async throws -> T {
    for _ in 0..<3000 {
        if let value = try await probe() { return value }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    throw CancellationError()
}

/// 一个真实的临时目录，测试结束时删掉。库文件落在这里——要验的正是落盘。
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "AgentreStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

let fixedNow: Int64 = 1_900_000_000_000

/// 在同一个目录上开一个新的库实例。冷启动 = 前一个实例已放掉，这里重新打开。
func openStore(_ directory: TemporaryDirectory) throws -> LocalConversationStore {
    try LocalConversationStore(directory: directory.url, now: { fixedNow })
}

func summary(
    _ conversationID: String, title: String = "", lastMessageAt: Int64 = 0, peer: String = ""
) -> Agentre_Wire_SessionSummary {
    var s = Agentre_Wire_SessionSummary()
    s.conversationID = conversationID
    s.peerFingerprint = peer
    s.title = title
    s.agentSyncID = "agent-\(conversationID)"
    s.cwd = "/work/\(conversationID)"
    s.projectSyncID = "project-1"
    s.backendType = "claudecode"
    s.lifecycleState = "idle"
    s.waitingForInput = true
    s.latestSeq = 999 // 机器的高水位，不是本机的游标
    s.lastMessageAt = lastMessageAt
    return s
}

/// 一帧持久的 runtime.event；`text` 让两帧同号不同内容时分得开。
func event(_ conversationID: String, seq: Int64, text: String = "", preview: Bool = false) -> Agentre_Wire_RpcNotification {
    var e = Agentre_Wire_RuntimeEventNotification()
    e.conversationID = conversationID
    e.seq = seq
    e.preview = preview
    var delta = Agentre_Wire_TextDelta()
    delta.text = text.isEmpty ? "frame \(seq)" : text
    e.textDelta = delta
    var n = Agentre_Wire_RpcNotification()
    n.runtimeEvent = e
    return n
}

func pulled(_ conversationID: String, seq: Int64, createtime: Int64, text: String = "") -> IncomingFrame {
    // 补齐拉回的帧：号在载体上，载荷里可以没有（对端不保证盖进去）。
    var payload = event(conversationID, seq: 0, text: text.isEmpty ? "frame \(seq)" : text)
    payload.runtimeEvent.seq = 0
    return IncomingFrame(conversationID: conversationID, seq: seq, createtime: createtime, payload: payload)
}

func live(_ conversationID: String, seq: Int64, text: String = "") -> IncomingFrame {
    IncomingFrame(conversationID: conversationID, seq: seq, createtime: nil, payload: event(conversationID, seq: seq, text: text))
}

func decode(_ frame: TranscriptFrame) throws -> Agentre_Wire_RpcNotification {
    try Agentre_Wire_RpcNotification(serializedBytes: frame.payload)
}

/// App 装配时那一行胶水：中继通道交出的通知原样转成库的入帧。
extension IncomingFrame {
    init(_ notification: RelayNotification) {
        self.init(
            conversationID: notification.conversationID, seq: notification.seq,
            createtime: notification.createtime, payload: notification.payload
        )
    }
}

// MARK: 伪中继

/// 期限与退让的等待一律挂住：这些测试不走超时与重连。
struct ParkedSleeper: Sleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

/// 中继服务端那一侧的伪物理连接：记下客户端写出的帧，测试往回推帧。
final class FakeSocket: RelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var outbound: [Data] = []
    private var answered: Set<String> = []
    private let inbound: AsyncThrowingStream<Data, any Error>
    private let feed: AsyncThrowingStream<Data, any Error>.Continuation

    init() { (inbound, feed) = AsyncThrowingStream.makeStream() }

    func send(_ frame: Data) async throws { lock.withLock { outbound.append(frame) } }

    func receive() async throws -> Data {
        var iterator = inbound.makeAsyncIterator()
        guard let next = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return next
    }

    func close() { feed.finish() }

    private var frames: [(channelID: String, payload: Data)] {
        lock.withLock { outbound }.map { try! RelayEnvelope.unwrap($0) }
    }

    func channelID(for target: RelayTarget) async throws -> String {
        try await eventually("declaration of \(target.declaration)") {
            frames.first { String(decoding: $0.payload, as: UTF8.self) == target.declaration }?.channelID
        }
    }

    func nextRequest(on channelID: String, method: Agentre_Wire_RpcMethod) async throws -> Agentre_Wire_RpcFrame {
        try await eventually("\(method) request") {
            let requests = frames.filter { $0.channelID == channelID }.dropFirst().compactMap {
                $0.payload.isEmpty ? nil : try? Agentre_Wire_RpcFrame(serializedBytes: $0.payload)
            }.filter {
                if case .request(let request)? = $0.body { return request.methodID == UInt32(method.rawValue) }
                return false
            }
            return lock.withLock {
                guard let frame = requests.first(where: { !answered.contains("\(channelID)#\($0.id)") }) else { return nil }
                answered.insert("\(channelID)#\(frame.id)")
                return frame
            }
        }
    }

    func push(_ channelID: String, _ payload: Data) {
        feed.yield(try! RelayEnvelope.wrap(channelID: channelID, payload: payload))
    }

    func respond(_ channelID: String, to request: Agentre_Wire_RpcFrame, with message: some SwiftProtobuf.Message) {
        var frame = Agentre_Wire_RpcFrame()
        frame.id = request.id
        var response = Agentre_Wire_Response()
        response.methodID = request.request.methodID
        response.encodedPayload = try! message.serializedData()
        frame.response = response
        push(channelID, try! frame.serializedData())
    }

    func notify(_ channelID: String, _ notification: Agentre_Wire_RpcNotification) {
        var frame = Agentre_Wire_RpcFrame()
        frame.notification = notification
        push(channelID, try! frame.serializedData())
    }

    func acceptHandshake(on channelID: String) async throws {
        let request = try await nextRequest(on: channelID, method: .authAccount)
        var response = Agentre_Wire_AuthAccountResponse()
        response.ok = true
        response.protocolVersion = RelayProtocol.version
        response.minSupportedProtocolVersion = RelayProtocol.version
        respond(channelID, to: request, with: response)
    }
}

final class FakeDialer: RelaySocketDialing, @unchecked Sendable {
    let socket = FakeSocket()
    func dial(url: URL, accessToken: String) async throws -> any RelaySocket { socket }
}

/// 一条握手完成的真实中继通道，对端是伪 socket。
/// 与装配层同一种接法：按对话订阅通道，每到一帧就落库（ConversationSync.follow）。
/// 订阅在交回之前已经挂上，此后 attach 补齐拉回的帧不会漏掉。
func follow(
    _ conversationIDs: [String], on channel: RelayChannel, into store: LocalConversationStore, via machine: String
) async -> Task<Void, Never> {
    var streams: [AsyncStream<RelayNotification>] = []
    for conversationID in conversationIDs {
        streams.append(await channel.subscribe(conversationID: conversationID))
    }
    let subscriptions = streams
    return Task {
        await withTaskGroup(of: Void.self) { group in
            for stream in subscriptions {
                group.addTask {
                    for await notification in stream {
                        try? await store.record([IncomingFrame(notification)], via: machine)
                    }
                }
            }
        }
    }
}

func readyChannel(_ target: RelayTarget) async throws -> (RelayConnection, RelayChannel, FakeSocket, String) {
    let dialer = FakeDialer()
    let connection = RelayConnection(
        url: URL(string: "wss://relay.test/v1/relay/client")!,
        dialer: dialer, accessToken: { "token" }, sleeper: ParkedSleeper()
    )
    await connection.start()
    let channel = await connection.channel(for: target)
    let id = try await dialer.socket.channelID(for: target)
    try await dialer.socket.acceptHandshake(on: id)
    _ = try await eventually("channel ready") { await channel.status == .ready ? true : nil }
    return (connection, channel, dialer.socket, id)
}

func durable(_ conversationID: String, seq: Int64, createtime: Int64) -> Agentre_Wire_DurableNotification {
    var n = Agentre_Wire_DurableNotification()
    n.seq = seq
    n.payload = event(conversationID, seq: 0)
    n.createtime = createtime
    return n
}
