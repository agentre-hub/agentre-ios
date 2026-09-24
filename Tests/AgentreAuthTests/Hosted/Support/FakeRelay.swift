import AgentreDomain
import AgentreRelay
import Foundation

/// 伪中继：一条物理连接上按信封多路复用，每条通道的第一帧是目标声明（`machine:<指纹>`），
/// 其后是 RpcFrame。请求交给 `machines` 里对应的伪机器作答；实时通知由测试经 `notify` 推下去。
final class FakeRelay: RelaySocketDialing, @unchecked Sendable {
    struct Call {
        let target: String
        let method: UInt32
        let payload: ProtoFields
    }

    private let lock = NSLock()
    private var machinesByTarget: [String: FakeMachine] = [:]
    private var recorded: [Call] = []
    private var sockets: [FakeRelaySocket] = []
    private var reachable = true
    private var answeredVersion = RelayProtocol.version
    private var beforeAnswer: (@Sendable (UInt32) async -> Void)?

    init(_ machines: [FakeMachine] = []) {
        for machine in machines { machinesByTarget["machine:\(machine.fingerprint)"] = machine }
    }

    /// 断网：此后拨号失败，已有的连接断开。
    func goOffline() {
        let open = lock.withLock {
            reachable = false
            return sockets
        }
        for socket in open { socket.close() }
        forgetConnections(in: machines)
    }

    /// 连接断了（应用在后台被挂起、换了网）：已有的连接断开，网络仍在，重拨照常拨得通。
    func dropConnections() {
        let open = lock.withLock {
            defer { sockets = [] }
            return sockets
        }
        for socket in open { socket.close() }
        forgetConnections(in: machines)
    }

    private var machines: [FakeMachine] { lock.withLock { Array(machinesByTarget.values) } }

    /// agentred 的会话表是按连接的：连接断了，那边认下的会话随之作废，重连后要重新 attach。
    private func forgetConnections(in machines: [FakeMachine]) {
        for machine in machines { machine.connectionLost() }
    }

    var calls: [Call] { lock.withLock { recorded } }

    /// 握手应答里报的协议版本（默认与本 App 相等）。
    func answerHandshakes(withVersion version: String) {
        lock.withLock { answeredVersion = version }
    }

    /// 每个请求作答之前先跑一下（按方法号），模拟应答在途时本机发生的事。
    func beforeAnswering(_ hook: @escaping @Sendable (UInt32) async -> Void) {
        lock.withLock { beforeAnswer = hook }
    }

    fileprivate func runBeforeAnswer(_ method: UInt32) async {
        let hook = lock.withLock { beforeAnswer }
        await hook?(method)
    }

    func calls(_ method: UInt32) -> [Call] { calls.filter { $0.method == method } }

    func dial(url: URL, accessToken: String) async throws -> any RelaySocket {
        try lock.withLock {
            guard reachable else { throw URLError(.notConnectedToInternet) }
            let socket = FakeRelaySocket(relay: self)
            sockets.append(socket)
            return socket
        }
    }

    /// 在声明了 `target` 的每条通道上推一帧实时通知。
    func notify(_ target: String, _ notification: Proto) {
        let open = lock.withLock { sockets }
        let frame = Proto { $0.message(4, notification) }
        for socket in open { socket.push(frame.data, toChannelsDeclaring: target) }
    }

    /// 服务端判死声明了 `target` 的每条通道（空载荷）。
    func closeChannels(_ target: String) {
        let open = lock.withLock { sockets }
        for socket in open { socket.push(Data(), toChannelsDeclaring: target) }
        forgetConnections(in: lock.withLock { machinesByTarget[target].map { [$0] } ?? [] })
    }

    /// 一次请求的应答：结果，或 RpcError（码 + 原文）。
    enum Reply {
        case result(Proto)
        case error(code: Int64, message: String)
    }

    fileprivate func respond(target: String, method: UInt32, payload: Data) -> Reply {
        let call = Call(target: target, method: method, payload: ProtoFields(payload))
        let machine = lock.withLock {
            recorded.append(call)
            return machinesByTarget[target]
        }
        if method == WireMethod.authAccount {
            let version = lock.withLock { answeredVersion }
            return .result(Proto { r in
                r.bool(1, true)
                r.string(3, version)
            })
        }
        return machine?.answer(call) ?? .error(code: -32601, message: "not implemented")
    }
}

final class FakeRelaySocket: RelaySocket, @unchecked Sendable {
    private let relay: FakeRelay
    private let lock = NSLock()
    private var channels: [String: String] = [:]
    private let incoming: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation

    fileprivate init(relay: FakeRelay) {
        self.relay = relay
        (incoming, sink) = AsyncStream.makeStream()
    }

    func send(_ frame: Data) async throws {
        let bytes = [UInt8](frame)
        guard bytes.count >= 2 else { return }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        let channel = String(decoding: bytes[2..<2 + length], as: UTF8.self)
        let payload = Data(bytes[(2 + length)...])
        let target: String? = lock.withLock {
            if let known = channels[channel] { return known }
            channels[channel] = String(decoding: payload, as: UTF8.self)
            return nil
        }
        guard let target, !payload.isEmpty else { return }
        let rpc = ProtoFields(payload)
        guard let request = rpc.message(2) else { return }
        let method = UInt32(request.varint(1))
        await relay.runBeforeAnswer(method)
        let answer = relay.respond(target: target, method: method, payload: request.bytes(2) ?? Data())
        let response: Proto
        switch answer {
        case .result(let result):
            response = Proto { f in
                f.varint(1, rpc.varint(1))
                f.message(3, Proto { r in
                    r.varint(1, UInt64(method))
                    r.bytes(2, result.data)
                })
            }
        case .error(let code, let message):
            response = Proto { f in
                f.varint(1, rpc.varint(1))
                f.message(5, Proto { e in
                    e.int(1, code)
                    e.string(2, message)
                })
            }
        }
        sink.yield(Self.envelope(channel, response.data))
    }

    func receive() async throws -> Data {
        for await frame in incoming { return frame }
        throw URLError(.networkConnectionLost)
    }

    func close() {
        sink.finish()
    }

    fileprivate func push(_ payload: Data, toChannelsDeclaring target: String) {
        let ids = lock.withLock { channels.filter { $0.value == target }.map(\.key) }
        for id in ids { sink.yield(Self.envelope(id, payload)) }
    }

    private static func envelope(_ channel: String, _ payload: Data) -> Data {
        let id = Data(channel.utf8)
        var data = Data([UInt8(id.count >> 8), UInt8(id.count & 0xFF)])
        data.append(id)
        data.append(payload)
        return data
    }
}

/// 伪机器：一份会话清单与每条会话的持久帧，按 wire 方法作答。
///
/// 控制面照搬 agentred：会话只在一轮跑着时登记在内存表里（runtime.run 登记、一轮收场即摘掉），
/// 不在表里时 runtime.setPermissionMode 回「没有进行中的一轮」
/// （agentre/internal/daemon/handlers/runtime.go:1454-1462、:1682-1689，码 rpcerror.CodeRuntimeNoActiveTurn）。
/// 插话与取回解的是这条连接的会话表（resolveSessionCapability → resolveSession，runtime.go:1349-1363、:1682-1689）：
/// session.attach 放一行占位（AdoptForPeer，runtime.go:243-254），手机自己开的一轮顶掉它、收场时连同摘掉
/// （fanout 先 unregister 再发 run_result_done，runtime.go:940-941）；表里没有时回同一个码。连接断了表就空了。
///
/// 会话清单照搬 agentred 的发起端回显：只标在**别的对端**发起的会话上，调用方自己发起的那几条
/// peer_fingerprint 为空（agentre/internal/daemon/handlers/session_catchup.go:167 `row.PeerFingerprint != peer`）。
/// 调用方是中继按访问令牌认出的那台设备，不在任何请求字段里，所以由 `caller` 给出。
/// 真实清单里别人发起的行从不为空：不给发起端的会话算作机器自己发起的，报机器自己的指纹（桌面端作承载机时即如此）。
final class FakeMachine: @unchecked Sendable {
    struct Session {
        var conversationID: String
        /// 发起端；空 = 机器自己。
        var peerFingerprint = ""
        var title = ""
        var lifecycleState = "idle"
        var waitingForInput = false
        var lastMessageAt: Int64 = 0
        var backendType = "claudecode"
        var cwd = "/work"
    }

    let fingerprint: String
    /// 此刻连着中继的那台设备（手机）的指纹。
    private let caller: @Sendable () -> String
    private let lock = NSLock()
    private var sessions: [Session] = []
    private var frames: [String: [(seq: Int64, notification: Proto)]] = [:]
    /// 此刻有一轮在跑的会话（agentred 的 RuntimeHandlers.sessions 里这一轮的属主行）。
    private var activeTurns: Set<String> = []
    /// 这条连接 attach 时认下的会话（RuntimeHandlers.sessions 里的占位行）。
    private var adopted: Set<String> = []
    /// 每条会话的插话信箱：runtime.steer 放进去，runtime.drainPending 整个取走（agentred 的 steer mailbox）。
    private var mailboxes: [String: [(queuedID: String, text: String)]] = [:]

    init(fingerprint: String, caller: @escaping @Sendable () -> String = { "" }) {
        self.fingerprint = fingerprint
        self.caller = caller
    }

    func add(_ session: Session, frames: [Proto]) {
        lock.withLock {
            sessions.append(session)
            self.frames[session.conversationID] = frames.enumerated().map { (Int64($0.offset + 1), $0.element) }
        }
    }

    /// 机器上这条会话又多了几帧（按到达次序接着编号）；交回新帧的号。
    @discardableResult
    func append(_ conversationID: String, _ more: [Proto]) -> [Int64] {
        lock.withLock {
            var existing = frames[conversationID] ?? []
            let seqs = more.indices.map { Int64(existing.count + $0 + 1) }
            existing += zip(seqs, more).map { ($0, $1) }
            frames[conversationID] = existing
            return seqs
        }
    }

    /// 这一轮收场：agentred 在 fanout 结束时把会话从内存表里摘掉。
    func finishTurn(_ conversationID: String) {
        _ = lock.withLock { activeTurns.remove(conversationID) }
    }

    /// 手机的连接断了：agentred 为那条连接建的会话表随之作废。
    func connectionLost() {
        lock.withLock {
            activeTurns = []
            adopted = []
        }
    }

    /// 会话的发起端：没给的算机器自己发起的。
    private func origin(of session: Session) -> String {
        session.peerFingerprint.isEmpty ? fingerprint : session.peerFingerprint
    }

    /// 会话行上的生命周期（agentred 开一轮落 running、收场落 idle / failed），会话清单照它答。
    func setLifecycle(_ conversationID: String, _ state: String) {
        lock.withLock {
            guard let index = sessions.firstIndex(where: { $0.conversationID == conversationID }) else { return }
            sessions[index].lifecycleState = state
        }
    }

    func answer(_ call: FakeRelay.Call) -> FakeRelay.Reply {
        lock.withLock {
            switch call.method {
            case WireMethod.runtimeSetPermissionMode:
                guard activeTurns.contains(call.payload.string(1)) else {
                    return .error(code: -32010, message: "agentruntime: no active turn for session")
                }
                return .result(Proto())
            case WireMethod.runtimeRun:
                let id = call.payload.string(3)
                activeTurns.insert(id)
                adopted.remove(id)
                if let index = sessions.firstIndex(where: { $0.conversationID == id }) { sessions[index].lifecycleState = "running" }
                return .result(Proto { $0.string(1, id) })
            case WireMethod.sessionAttach:
                adopted.insert(call.payload.string(1))
                return .result(sessionAnswer(call))
            case WireMethod.runtimeSteer:
                guard resolves(call.payload.string(1)) else {
                    return .error(code: -32010, message: "agentruntime: no active turn for session")
                }
                mailboxes[call.payload.string(1), default: []].append((call.payload.string(3), call.payload.string(4)))
                return .result(Proto { r in
                    r.string(1, call.payload.string(3))
                    r.bool(2, true)
                })
            case WireMethod.runtimeDrainPending:
                guard resolves(call.payload.string(1)) else {
                    return .error(code: -32010, message: "agentruntime: no active turn for session")
                }
                let steers = mailboxes.removeValue(forKey: call.payload.string(1)) ?? []
                return .result(Proto { r in
                    for steer in steers {
                        r.message(1, Proto { c in
                            c.string(1, steer.queuedID)
                            c.string(2, steer.text)
                        })
                    }
                })
            default:
                return .result(sessionAnswer(call))
            }
        }
    }

    /// 这条连接的会话表里有这一行（resolveSession）；调用方持锁。
    private func resolves(_ conversationID: String) -> Bool {
        activeTurns.contains(conversationID) || adopted.contains(conversationID)
    }

    /// 会话取材与其余方法的应答；调用方持锁。
    private func sessionAnswer(_ call: FakeRelay.Call) -> Proto {
        switch call.method {
        case WireMethod.sessionList:
            let caller = caller()
            return Proto { r in
                for session in sessions {
                    r.message(1, Proto { s in
                        s.string(1, session.conversationID)
                        s.string(2, origin(of: session) == caller ? "" : origin(of: session))
                        s.string(4, session.title)
                        s.string(7, session.cwd)
                        s.string(9, session.backendType)
                        s.string(10, session.lifecycleState)
                        s.bool(11, session.waitingForInput)
                        s.int(12, Int64(frames[session.conversationID]?.count ?? 0))
                        s.int(13, session.lastMessageAt)
                    })
                }
                r.int(4, Int64(sessions.count))
            }
        case WireMethod.sessionCounts:
            return Proto { r in
                r.int(1, Int64(sessions.count))
                r.int(2, Int64(sessions.count { $0.lifecycleState == "running" }))
                r.int(3, Int64(sessions.count { $0.waitingForInput }))
            }
        case WireMethod.sessionAttach:
            let id = call.payload.string(1)
            return Proto { r in
                r.string(1, id)
                r.int(4, Int64(frames[id]?.count ?? 0))
            }
        case WireMethod.sessionPull:
            let id = call.payload.string(1)
            let cursor = call.payload.int(3)
            let page = (frames[id] ?? []).filter { $0.seq > cursor }
            return Proto { r in
                for frame in page {
                    r.message(1, Proto { d in
                        d.int(1, frame.seq)
                        d.message(2, frame.notification)
                        d.int(3, 1_700_000_000_000 + frame.seq)
                    })
                }
                r.int(2, page.last?.seq ?? cursor)
                r.int(4, frames[id]?.isEmpty == false ? 1 : 0)
            }
        case WireMethod.runtimeCapabilities:
            return Proto { r in
                r.message(2, Proto { m in
                    m.string(1, "default")
                    m.string(1, "plan")
                    m.string(2, "default")
                })
            }
        default:
            // 其余（作答、Skill 目录……）一律空应答：解成对应消息的默认值。
            return Proto()
        }
    }
}
