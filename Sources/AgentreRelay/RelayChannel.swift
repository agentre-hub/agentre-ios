import AgentreDomain
import AgentreWire
import Foundation
import SwiftProtobuf

/// 一条虚拟通道：对通道那一头的机器说 wire 协议。
///
/// - 多路复用：一条通道上可以并发多个请求，应答按请求 id 路由，互不串道。
/// - 握手逐通道进行：每次（重）连都向对端出示设备 access token（auth.account）。握手
///   完成前发起的调用先排着，握手后才发出。
/// - 协议版本不等时停止重试这一条，状态落到 `.updateRequired`；其它握手失败按退让重试。
/// - 断线补齐：重连握手后对关注的对话重新 attach，按 `seq` 游标 pull；拉回的帧与实时帧
///   走同一条投递路径，`seq` 不大于游标者为重复，只应用一次。同一对话的补齐一轮接一轮，
///   不并行；补齐期间到达的实时帧（含不带号的轮次边界）等补完再按到达次序交出；实时帧跳号
///   即按游标补拉缺口。
/// - 每次调用都有兜底期限，到期以 `.timedOut` 收场并向对端发出取消。
public actor RelayChannel {
    public static let defaultDeadline: Duration = .seconds(30)

    public nonisolated let target: RelayTarget
    /// 状态的变化。状态是一个值，没人读时只留最新的一个。
    public nonisolated let statusUpdates: AsyncStream<RelayChannelStatus>
    public private(set) var status: RelayChannelStatus = .connecting

    private struct Pending {
        let method: UInt32
        let frame: Data
        var sent: Bool
        let continuation: CheckedContinuation<Data, any Error>
        var timer: Task<Void, Never>?
    }

    private struct Conversation {
        var cursor: Int64
        var peerFingerprint: String
        var watched = false
        var catchingUp = false
        /// 补齐进行中到达的实时帧，补完之后再按同一条路径应用。
        var buffered: [Agentre_Wire_RpcNotification] = []
        /// 排在最后的那一轮补齐（在途或等着前一轮）；新的一轮接在它后面。
        var lastCatchUp: (token: UUID, task: Task<Agentre_Wire_SessionAttachResponse, any Error>)?
        /// 那一轮是上次断线之后排的：它的请求还没随断线收场，重连就绪后由它补齐。
        var catchUpSinceLoss = false
    }

    private let id: String
    private weak var connection: RelayConnection?
    private let accessToken: @Sendable () async throws -> String
    private let sleeper: any Sleeping
    private let random: @Sendable () -> Double
    private let backoff: RelayBackoff
    private let statusSink: AsyncStream<RelayChannelStatus>.Continuation

    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: Pending] = [:]
    private var ready = false
    private var halted = false
    private var closed = false
    /// 每次（重）连或断线加一；过期的握手据此认出自己已经作废。
    private var generation = 0
    private var handshakeFailures = 0
    private var handshakeTask: Task<Void, Never>?
    private var conversations: [String: Conversation] = [:]
    /// 按对话订阅的交出口：一条机器通道承载多条对话，各屏只要自己那一条。
    private var subscribers: [String: [UUID: Subscriber]] = [:]

    private enum Subscriber {
        case notifications(AsyncStream<RelayNotification>.Continuation)
        case events(AsyncStream<RelayConversationEvent>.Continuation)

        func finish() {
            switch self {
            case .notifications(let continuation): continuation.finish()
            case .events(let continuation): continuation.finish()
            }
        }
    }

    init(
        id: String,
        target: RelayTarget,
        connection: RelayConnection,
        accessToken: @escaping @Sendable () async throws -> String,
        sleeper: any Sleeping,
        random: @escaping @Sendable () -> Double,
        backoff: RelayBackoff
    ) {
        self.id = id
        self.target = target
        self.connection = connection
        self.accessToken = accessToken
        self.sleeper = sleeper
        self.random = random
        self.backoff = backoff
        (statusUpdates, statusSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: 公开调用

    /// 发一次 RPC 并等它的应答。握手完成前先排着；到 `deadline` 仍无应答即抛 `.timedOut`。
    public func call<Response: SwiftProtobuf.Message>(
        _ method: Agentre_Wire_RpcMethod,
        _ request: some SwiftProtobuf.Message,
        as type: Response.Type = Response.self,
        deadline: Duration = RelayChannel.defaultDeadline
    ) async throws -> Response {
        let payload = try await send(method, request, gated: true, deadline: deadline)
        do {
            return try Response(serializedBytes: payload)
        } catch {
            throw RelayCallError.unexpectedResponse
        }
    }

    /// 关注一条对话：attach，再从 `cursor`（调用方已有的最大 seq）起按游标拉齐。
    /// 此后每次重连都自动重做 attach 与补齐。
    ///
    /// 游标以调用方给的为准：通道自己的游标可能已经越过调用方没拿到的帧（上一次跟随中途断了、
    /// 帧交给了别的订阅方），取二者之大会让那些帧再也补不回来。seq 大于 `cursor` 的帧都会
    /// （再）交出一次，已经拿到的由订阅方按 seq 去重。
    ///
    /// 会话已中断（对端 attach 回 no active turn）时历史照拉：交回的应答生命周期为
    /// `interrupted`，最高帧号取拉到的最后一帧。
    public func attach(
        conversationID: String, peerFingerprint: String = "", after cursor: Int64 = 0
    ) async throws -> Agentre_Wire_SessionAttachResponse {
        var conversation = conversations[conversationID] ?? Conversation(cursor: cursor, peerFingerprint: peerFingerprint)
        conversation.peerFingerprint = peerFingerprint
        conversation.watched = true
        conversations[conversationID] = conversation
        let task = scheduleCatchUp(conversationID, from: cursor)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 订阅一条对话的通知（已去重；预览帧也在内）。可以有多个订阅方；流在通道关闭时结束。
    public func subscribe(conversationID: String) -> AsyncStream<RelayNotification> {
        let (stream, continuation) = AsyncStream<RelayNotification>.makeStream()
        if let token = register(conversationID, .notifications(continuation)) {
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(conversationID, token) }
            }
        }
        return stream
    }

    /// 订阅一条对话的通知，外加每一次 attach 的应答（含重连后通道自己重做的那些）。应答排在
    /// 那一轮补拉的帧之前：跟随方据它先回退游标、刷新摘要，再落随后的帧。
    public func events(conversationID: String) -> AsyncStream<RelayConversationEvent> {
        let (stream, continuation) = AsyncStream<RelayConversationEvent>.makeStream()
        if let token = register(conversationID, .events(continuation)) {
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(conversationID, token) }
            }
        }
        return stream
    }

    /// 挂上一个订阅方；通道已关闭时当场结束它的流、交回 nil。
    private func register(_ conversationID: String, _ subscriber: Subscriber) -> UUID? {
        guard !closed, !halted else {
            subscriber.finish()
            return nil
        }
        let token = UUID()
        subscribers[conversationID, default: [:]][token] = subscriber
        return token
    }

    private func unsubscribe(_ conversationID: String, _ token: UUID) {
        subscribers[conversationID]?[token] = nil
        if subscribers[conversationID]?.isEmpty == true { subscribers[conversationID] = nil }
    }

    /// 交出一条通知：订阅了这条对话的每一方各一份。
    private func emit(_ notification: RelayNotification) {
        guard let conversationID = notification.conversationID else { return }
        for subscriber in Array(subscribers[conversationID, default: [:]].values) {
            switch subscriber {
            case .notifications(let continuation): continuation.yield(notification)
            case .events(let continuation): continuation.yield(.notification(notification))
            }
        }
    }

    private func emitAttached(latestSeq: Int64?, conversationID: String) {
        for subscriber in Array(subscribers[conversationID, default: [:]].values) {
            if case .events(let continuation) = subscriber { continuation.yield(.attached(latestSeq: latestSeq)) }
        }
    }

    private func finishSubscribers() {
        let all = subscribers.values.flatMap(\.values)
        subscribers = [:]
        for subscriber in all { subscriber.finish() }
    }

    /// 某条对话已应用到的最大 seq。
    public func cursor(conversationID: String) -> Int64 {
        conversations[conversationID]?.cursor ?? 0
    }

    // MARK: 连接回调

    /// 连接就绪且本通道的目标已声明：做本通道的握手。
    func opened() {
        guard !halted, !closed else { return }
        generation += 1
        ready = false
        setStatus(.connecting)
        startHandshake(generation)
    }

    /// 物理连接断了：已发出的请求结果未知，立即收场；排着的请求留到重连后再发。
    func connectionLost() {
        guard !halted, !closed else { return }
        generation += 1
        ready = false
        handshakeTask?.cancel()
        handshakeTask = nil
        for conversationID in conversations.keys { conversations[conversationID]?.catchUpSinceLoss = false }
        for (requestID, entry) in pending where entry.sent {
            settle(requestID, .failure(RelayCallError.disconnected))
        }
        setStatus(.reconnecting)
    }

    /// 通道被关闭（服务端判死，或整条连接被停掉）。
    func shutdown() {
        guard !closed else { return }
        closed = true
        ready = false
        handshakeTask?.cancel()
        failAll(halted ? .updateRequired : .channelClosed)
        finishSubscribers()
        if !halted { setStatus(.closed) }
    }

    /// 本通道收到一帧载荷。
    func receive(_ payload: Data) {
        guard let frame = try? Agentre_Wire_RpcFrame(serializedBytes: payload) else { return }
        switch frame.body {
        case .response(let response):
            guard let entry = pending[frame.id] else { return }
            if response.methodID == entry.method {
                settle(frame.id, .success(response.encodedPayload))
            } else {
                settle(frame.id, .failure(RelayCallError.unexpectedResponse))
            }
        case .error(let error):
            // id 为 0 的是通道级错误，随后会到一帧关闭；它自己不需要处理。
            guard frame.id != 0 else { return }
            settle(frame.id, .failure(RelayCallError.rejected(code: error.code)))
        case .notification(let notification):
            deliver(notification, createtime: nil, live: true)
        default:
            return
        }
    }

    // MARK: 握手

    private func startHandshake(_ generation: Int) {
        handshakeTask?.cancel()
        handshakeTask = Task { await self.handshake(generation) }
    }

    private func handshake(_ generation: Int) async {
        do {
            var request = Agentre_Wire_AuthAccountRequest()
            request.credential = try await accessToken()
            request.protocolVersion = RelayProtocol.version
            request.minSupportedProtocolVersion = RelayProtocol.version
            let payload = try await send(.authAccount, request, gated: false, deadline: Self.defaultDeadline)
            let response = try Agentre_Wire_AuthAccountResponse(serializedBytes: payload)
            guard generation == self.generation else { return }
            if !response.protocolVersion.isEmpty, response.protocolVersion != RelayProtocol.version {
                await halt()
                return
            }
            becomeReady()
        } catch RelayCallError.rejected(let code) where code == RelayProtocol.errorCodeProtocolVersion {
            // 同一个对端不会自己变新，重试永远换不来别的答案。
            await halt()
        } catch {
            guard generation == self.generation, !halted, !closed else { return }
            setStatus(.reconnecting)
            let delay = backoff.delay(afterFailures: handshakeFailures, random: random())
            handshakeFailures += 1
            do { try await sleeper.sleep(for: delay) } catch { return }
            guard generation == self.generation else { return }
            await handshake(generation)
        }
    }

    private func becomeReady() {
        ready = true
        handshakeFailures = 0
        setStatus(.ready)
        for (requestID, entry) in pending where !entry.sent {
            transmit(requestID)
        }
        // 这一代连接上已经排着一轮的（握手前发起的 attach）由那一轮补齐，不再叠一轮；
        // 断线前那一轮的请求已随断线收场，新的一轮接在它后面。
        for (conversationID, conversation) in conversations where conversation.watched {
            if conversation.lastCatchUp != nil, conversation.catchUpSinceLoss { continue }
            scheduleCatchUp(conversationID, from: nil)
        }
    }

    /// 协议版本不等：这一条停止重试，并从连接上摘掉（重连时不再为它声明、握手）。
    private func halt() async {
        guard !halted else { return }
        halted = true
        ready = false
        failAll(.updateRequired)
        finishSubscribers()
        setStatus(.updateRequired)
        await connection?.close(id)
    }

    // MARK: 补齐

    /// 排一轮补齐，接在这条对话上一轮的后面（一轮接一轮，缓冲与游标不会被两轮交错着改）。
    /// `cursor` 为 nil 时从通道自己的游标接着拉。
    @discardableResult
    private func scheduleCatchUp(
        _ conversationID: String, from cursor: Int64?
    ) -> Task<Agentre_Wire_SessionAttachResponse, any Error> {
        let previous = conversations[conversationID]?.lastCatchUp?.task
        let token = UUID()
        let task = Task { () async throws -> Agentre_Wire_SessionAttachResponse in
            _ = await previous?.result
            let outcome: Result<Agentre_Wire_SessionAttachResponse, any Error>
            do {
                outcome = .success(try await self.catchUp(conversationID, from: cursor))
            } catch {
                outcome = .failure(error)
            }
            await self.catchUpEnded(conversationID, token)
            return try outcome.get()
        }
        conversations[conversationID]?.lastCatchUp = (token, task)
        conversations[conversationID]?.catchUpSinceLoss = true
        return task
    }

    private func catchUpEnded(_ conversationID: String, _ token: UUID) {
        guard conversations[conversationID]?.lastCatchUp?.token == token else { return }
        conversations[conversationID]?.lastCatchUp = nil
    }

    private func catchUp(_ conversationID: String, from start: Int64?) async throws -> Agentre_Wire_SessionAttachResponse {
        try Task.checkCancellation()
        guard let conversation = conversations[conversationID] else { throw RelayCallError.channelClosed }
        if let start { conversations[conversationID]?.cursor = start }
        conversations[conversationID]?.catchingUp = true
        do {
            var attach = Agentre_Wire_SessionAttachRequest()
            attach.conversationID = conversationID
            attach.peerFingerprint = conversation.peerFingerprint
            var attached: Agentre_Wire_SessionAttachResponse
            var interrupted = false
            do {
                attached = try await call(.sessionAttach, attach)
            } catch RelayCallError.rejected(let code) where code == RelayProtocol.errorCodeNoActiveTurn {
                // 那一轮的进程已随上一个对端进程消亡，接不回实时流；历史仍可 pull（mirror_svc.catchUp）。
                attached = Agentre_Wire_SessionAttachResponse()
                attached.conversationID = conversationID
                attached.lifecycleState = SavedConversation.Lifecycle.interrupted
                interrupted = true
            }
            // 游标只可能来自对端发过的帧号，越过它的最高帧号只说明对端的帧号重新起算了
            // （整条会话被删、会话号被复用）。不回退的话此后每一帧都被当成重复丢掉，
            // 会话无声冻住（mirror_svc 与桌面端 reconnect.go 的 dropCursorAboveHighWater）。
            if !interrupted, cursor(conversationID: conversationID) > attached.latestSeq {
                conversations[conversationID]?.cursor = 0
            }
            emitAttached(latestSeq: interrupted ? nil : attached.latestSeq, conversationID: conversationID)
            while true {
                let before = cursor(conversationID: conversationID)
                var pull = Agentre_Wire_SessionPullRequest()
                pull.conversationID = conversationID
                pull.peerFingerprint = conversation.peerFingerprint
                pull.cursor = before
                pull.limit = RelayProtocol.pullLimit
                let page: Agentre_Wire_SessionPullResponse = try await call(.sessionPull, pull)
                for frame in page.notifications {
                    apply(frame.payload, conversationID: conversationID, seq: frame.seq, createtime: frame.createtime)
                }
                if page.cursor > cursor(conversationID: conversationID) {
                    conversations[conversationID]?.cursor = page.cursor
                }
                guard page.hasMore_p, cursor(conversationID: conversationID) > before else { break }
            }
            if interrupted { attached.latestSeq = cursor(conversationID: conversationID) }
            let buffered = conversations[conversationID]?.buffered ?? []
            conversations[conversationID]?.buffered = []
            conversations[conversationID]?.catchingUp = false
            for notification in buffered { deliver(notification, createtime: nil, live: false) }
            return attached
        } catch {
            // 缓冲的实时帧丢掉：游标没有前进，下一次补齐会把它们一并拉回。
            conversations[conversationID]?.buffered = []
            conversations[conversationID]?.catchingUp = false
            throw error
        }
    }

    /// 实时帧的投递入口。
    ///
    /// 补齐进行中到达的帧先缓冲，补完再按到达次序交出——不带号的轮次边界也一样，否则它会抢到
    /// 它所属那一轮、还在补拉的帧前面。预览帧是过场，照常立即交出（补完再交只会留下一段过时的
    /// 半句话）。关注中的对话实时帧跳了号（中间一帧在中继上丢了）：缓冲这一帧，按游标补拉缺口。
    private func deliver(_ notification: Agentre_Wire_RpcNotification, createtime: Int64?, live: Bool) {
        let key = notification.durableKey
        if live, let key, !notification.isPreviewFrame, let conversation = conversations[key.conversationID] {
            if conversation.catchingUp {
                conversations[key.conversationID]?.buffered.append(notification)
                return
            }
            if conversation.watched, key.seq > conversation.cursor + 1 {
                conversations[key.conversationID]?.buffered.append(notification)
                scheduleCatchUp(key.conversationID, from: nil)
                return
            }
        }
        guard let key, key.seq > 0 else {
            emit(RelayNotification(
                payload: notification, conversationID: key?.conversationID,
                seq: nil, createtime: createtime
            ))
            return
        }
        apply(notification, conversationID: key.conversationID, seq: key.seq, createtime: createtime)
    }

    /// 实时帧与补齐帧的会合点：`seq` 不大于游标即重复，只应用一次。
    private func apply(_ notification: Agentre_Wire_RpcNotification, conversationID: String, seq: Int64, createtime: Int64?) {
        var conversation = conversations[conversationID] ?? Conversation(cursor: 0, peerFingerprint: "")
        guard seq > conversation.cursor else { return }
        conversation.cursor = seq
        conversations[conversationID] = conversation
        emit(RelayNotification(
            payload: notification, conversationID: conversationID, seq: seq, createtime: createtime
        ))
    }

    // MARK: 请求簿记

    /// `gated`：握手完成前先排着（握手本身不受此限）。
    private func send(
        _ method: Agentre_Wire_RpcMethod, _ request: some SwiftProtobuf.Message, gated: Bool, deadline: Duration
    ) async throws -> Data {
        if halted { throw RelayCallError.updateRequired }
        if closed { throw RelayCallError.channelClosed }
        let requestID = nextRequestID
        nextRequestID += 1
        var body = Agentre_Wire_Request()
        body.methodID = UInt32(method.rawValue)
        body.encodedPayload = try request.serializedData()
        var frame = Agentre_Wire_RpcFrame()
        frame.id = requestID
        frame.request = body
        let bytes = try frame.serializedData()

        // 调用方被取消（屏关了、任务停了）：当场以取消收场，并告诉对端别再为它忙。
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let sleeper = self.sleeper
                let timer = Task { [weak self] in
                    do { try await sleeper.sleep(for: deadline) } catch { return }
                    await self?.abandon(requestID, RelayCallError.timedOut)
                }
                pending[requestID] = Pending(
                    method: body.methodID, frame: bytes, sent: false,
                    continuation: continuation, timer: timer
                )
                if Task.isCancelled {
                    Task { await self.abandon(requestID, CancellationError()) }
                    return
                }
                if ready || !gated { transmit(requestID) }
            }
        } onCancel: {
            Task { await self.abandon(requestID, CancellationError()) }
        }
    }

    private func transmit(_ requestID: UInt64) {
        guard var entry = pending[requestID], !entry.sent else { return }
        entry.sent = true
        pending[requestID] = entry
        Task { await self.write(entry.frame, failing: requestID) }
    }

    private func write(_ frame: Data, failing requestID: UInt64?) async {
        do {
            guard let connection else { throw RelayCallError.channelClosed }
            try await connection.write(id, frame)
        } catch {
            if let requestID { settle(requestID, .failure(error as? RelayCallError ?? .disconnected)) }
        }
    }

    /// 不再等这一条（到期或调用方取消）：以 `error` 收场；已发出的，向对端发出取消。
    private func abandon(_ requestID: UInt64, _ error: any Error) async {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        entry.timer?.cancel()
        entry.continuation.resume(throwing: error)
        guard entry.sent else { return }
        // 告诉对端别再为它忙了。发不出去也无妨：这一条照样已经收场。
        var cancel = Agentre_Wire_Cancel()
        cancel.requestID = requestID
        var frame = Agentre_Wire_RpcFrame()
        frame.id = nextRequestID
        nextRequestID += 1
        frame.cancel = cancel
        guard let bytes = try? frame.serializedData() else { return }
        await write(bytes, failing: nil)
    }

    private func settle(_ requestID: UInt64, _ result: Result<Data, any Error>) {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        entry.timer?.cancel()
        entry.continuation.resume(with: result)
    }

    private func failAll(_ error: RelayCallError) {
        for requestID in Array(pending.keys) { settle(requestID, .failure(error)) }
    }

    private func setStatus(_ next: RelayChannelStatus) {
        guard status != next else { return }
        status = next
        statusSink.yield(next)
    }
}
