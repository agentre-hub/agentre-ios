import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

/// 等一个条件成立（真实时间上限 2 秒）。只用来等并发的那一侧走到某一步，
/// 判据本身仍由断言给出，不靠时序。
func eventually<T>(
    _ what: String = "condition",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ probe: () async -> T?
) async throws -> T {
    for _ in 0..<2000 {
        if let value = await probe() { return value }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    throw CancellationError()
}

/// 伪时钟：每次等待都挂起到测试把时间推过它的期限；记下每一次等待的时长。
final class ManualClock: Sleeping, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var now: Duration = .zero
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<UUID> = []
    private var requested: [Duration] = []

    /// 迄今所有等待请求的时长，按发起顺序。
    var requestedSleeps: [Duration] { lock.withLock { requested } }
    /// 正挂着的等待（未到期、未取消）的时长。
    var pendingSleeps: [Duration] { lock.withLock { sleepers.map { $0.deadline - now } } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = lock.withLock {
                    requested.append(duration)
                    if cancelled.contains(id) { return true }
                    sleepers.append(Sleeper(id: id, deadline: now + duration, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                cancelled.insert(id)
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            now += duration
            let due = sleepers.filter { $0.deadline <= now }
            sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// 一次次给出预设的随机数，用完后重复最后一个。
final class ScriptedRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]
    init(_ values: [Double]) { self.values = values }
    func next() -> Double {
        lock.withLock { values.count > 1 ? values.removeFirst() : values[0] }
    }
}

/// 可变的 access token：模拟令牌在两次连接之间被刷新。
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String
    init(_ token: String) { self.token = token }
    var value: String {
        get { lock.withLock { token } }
        set { lock.withLock { token = newValue } }
    }
}

/// 中继服务端那一侧的伪物理连接：记下客户端写出的每一帧，测试往回推帧。
final class FakeSocket: RelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var outbound: [Data] = []
    private var answered: Set<String> = []
    private let inbound: AsyncThrowingStream<Data, any Error>
    private let feed: AsyncThrowingStream<Data, any Error>.Continuation
    private(set) var closed = false

    init() {
        (inbound, feed) = AsyncThrowingStream.makeStream()
    }

    func send(_ frame: Data) async throws {
        try lock.withLock {
            if closed { throw URLError(.networkConnectionLost) }
            outbound.append(frame)
        }
    }

    func receive() async throws -> Data {
        var iterator = inbound.makeAsyncIterator()
        guard let next = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return next
    }

    func close() {
        lock.withLock { closed = true }
        feed.finish()
    }

    // MARK: 测试这一侧

    /// 客户端写出的全部帧，拆开信封。
    var frames: [(channelID: String, payload: Data)] {
        lock.withLock { outbound }.map { try! RelayEnvelope.unwrap($0) }
    }

    /// 每条通道的第一帧（目标声明）：目标 → 通道 ID。
    var declarations: [String: String] {
        var seen: Set<String> = []
        var result: [String: String] = [:]
        for frame in frames where !seen.contains(frame.channelID) {
            seen.insert(frame.channelID)
            result[String(decoding: frame.payload, as: UTF8.self)] = frame.channelID
        }
        return result
    }

    /// 某条通道上除声明帧外客户端发出的 RPC 帧。
    func rpcFrames(on channelID: String) -> [Agentre_Wire_RpcFrame] {
        frames.filter { $0.channelID == channelID }.dropFirst().compactMap {
            $0.payload.isEmpty ? nil : try? Agentre_Wire_RpcFrame(serializedBytes: $0.payload)
        }
    }

    func requests(on channelID: String, method: Agentre_Wire_RpcMethod) -> [Agentre_Wire_RpcFrame] {
        rpcFrames(on: channelID).filter {
            if case .request(let request)? = $0.body { return request.methodID == UInt32(method.rawValue) }
            return false
        }
    }

    /// 等一条尚未应答过的某方法请求。
    func nextRequest(
        on channelID: String, method: Agentre_Wire_RpcMethod,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Agentre_Wire_RpcFrame {
        try await eventually("\(method) request on \(channelID)", sourceLocation: sourceLocation) {
            let candidates = requests(on: channelID, method: method)
            return lock.withLock {
                guard let frame = candidates.first(where: { !answered.contains("\(channelID)#\($0.id)") })
                else { return nil }
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

    func fail(_ channelID: String, to request: Agentre_Wire_RpcFrame, code: Int32, message: String) {
        var frame = Agentre_Wire_RpcFrame()
        frame.id = request.id
        var error = Agentre_Wire_RpcError()
        error.code = code
        error.message = message
        frame.error = error
        push(channelID, try! frame.serializedData())
    }

    func notify(_ channelID: String, _ notification: Agentre_Wire_RpcNotification) {
        var frame = Agentre_Wire_RpcFrame()
        frame.notification = notification
        push(channelID, try! frame.serializedData())
    }

    /// 网络断了：客户端的下一次 receive 抛出。
    func drop() {
        lock.withLock { closed = true }
        feed.finish(throwing: URLError(.networkConnectionLost))
    }
}

/// 伪拨号器：记下每次拨号出示的令牌；可预设前几次拨号失败。
final class FakeDialer: RelaySocketDialing, @unchecked Sendable {
    private let lock = NSLock()
    private var dialed: [(url: URL, token: String)] = []
    private var made: [FakeSocket] = []
    private var failuresLeft: Int

    init(failFirst failures: Int = 0) { failuresLeft = failures }

    var dials: [(url: URL, token: String)] { lock.withLock { dialed } }
    var sockets: [FakeSocket] { lock.withLock { made } }

    func dial(url: URL, accessToken: String) async throws -> any RelaySocket {
        try lock.withLock {
            dialed.append((url, accessToken))
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw URLError(.notConnectedToInternet)
            }
            let socket = FakeSocket()
            made.append(socket)
            return socket
        }
    }

    func socket(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws -> FakeSocket {
        try await eventually("socket #\(index)", sourceLocation: sourceLocation) {
            let all = sockets
            return all.count > index ? all[index] : nil
        }
    }
}

extension FakeSocket {
    /// 等某个目标的声明帧，交回其通道 ID。
    func channelID(
        for target: RelayTarget, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> String {
        try await eventually("declaration of \(target.declaration)", sourceLocation: sourceLocation) {
            declarations[target.declaration]
        }
    }

    /// 应答一次握手成功，交回那一帧请求（测试据它检查出示的凭据）。
    @discardableResult
    func acceptHandshake(
        on channelID: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Agentre_Wire_AuthAccountRequest {
        let request = try await nextRequest(on: channelID, method: .authAccount, sourceLocation: sourceLocation)
        var response = Agentre_Wire_AuthAccountResponse()
        response.ok = true
        response.protocolVersion = RelayProtocol.version
        response.minSupportedProtocolVersion = RelayProtocol.version
        respond(channelID, to: request, with: response)
        return try Agentre_Wire_AuthAccountRequest(serializedBytes: request.request.encodedPayload)
    }
}

let testURL = URL(string: "wss://relay.test/v1/relay/client")!

struct Harness {
    let dialer: FakeDialer
    let clock: ManualClock
    let token: TokenBox
    let connection: RelayConnection

    init(failFirstDials: Int = 0, random: [Double] = [0.5]) {
        let dialer = FakeDialer(failFirst: failFirstDials)
        let clock = ManualClock()
        let token = TokenBox("token-1")
        let scripted = ScriptedRandom(random)
        self.dialer = dialer
        self.clock = clock
        self.token = token
        connection = RelayConnection(
            url: testURL,
            dialer: dialer,
            accessToken: { token.value },
            sleeper: clock,
            random: { scripted.next() }
        )
    }

    /// 启动连接、开一条通道并完成它的握手。
    func readyChannel(_ target: RelayTarget) async throws -> (RelayChannel, FakeSocket, String) {
        await connection.start()
        let channel = await connection.channel(for: target)
        let socket = try await dialer.socket(0)
        let id = try await socket.channelID(for: target)
        try await socket.acceptHandshake(on: id)
        try await waitStatus(channel, .ready)
        return (channel, socket, id)
    }
}

func waitStatus(
    _ channel: RelayChannel, _ status: RelayChannelStatus,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    _ = try await eventually("status \(status)", sourceLocation: sourceLocation) {
        await channel.status == status ? true : nil
    }
}
