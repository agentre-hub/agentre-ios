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
    }

    var calls: [Call] { lock.withLock { recorded } }

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
    }

    fileprivate func respond(target: String, method: UInt32, payload: Data) -> Proto? {
        let call = Call(target: target, method: method, payload: ProtoFields(payload))
        let machine = lock.withLock {
            recorded.append(call)
            return machinesByTarget[target]
        }
        if method == WireMethod.authAccount {
            return Proto { r in
                r.bool(1, true)
                r.string(3, RelayProtocol.version)
            }
        }
        return machine?.answer(call)
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
        let answer = relay.respond(target: target, method: method, payload: request.bytes(2) ?? Data())
        let response: Proto
        if let answer {
            response = Proto { f in
                f.varint(1, rpc.varint(1))
                f.message(3, Proto { r in
                    r.varint(1, UInt64(method))
                    r.bytes(2, answer.data)
                })
            }
        } else {
            response = Proto { f in
                f.varint(1, rpc.varint(1))
                f.message(5, Proto { e in
                    e.int(1, -32601)
                    e.string(2, "not implemented")
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
final class FakeMachine: @unchecked Sendable {
    struct Session {
        var conversationID: String
        var peerFingerprint = ""
        var title = ""
        var lifecycleState = "idle"
        var waitingForInput = false
        var lastMessageAt: Int64 = 0
        var backendType = "claudecode"
        var cwd = "/work"
    }

    let fingerprint: String
    private let lock = NSLock()
    private var sessions: [Session] = []
    private var frames: [String: [(seq: Int64, notification: Proto)]] = [:]

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func add(_ session: Session, frames: [Proto]) {
        lock.withLock {
            sessions.append(session)
            self.frames[session.conversationID] = frames.enumerated().map { (Int64($0.offset + 1), $0.element) }
        }
    }

    func answer(_ call: FakeRelay.Call) -> Proto? {
        lock.withLock {
            switch call.method {
            case WireMethod.sessionList:
                return Proto { r in
                    for session in sessions {
                        r.message(1, Proto { s in
                            s.string(1, session.conversationID)
                            s.string(2, session.peerFingerprint)
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
            case WireMethod.runtimeRun:
                return Proto { $0.string(1, call.payload.string(3)) }
            case WireMethod.runtimeSteer:
                return Proto { r in
                    r.string(1, call.payload.string(3))
                    r.bool(2, true)
                }
            default:
                // 其余（作答、Skill 目录……）一律空应答：解成对应消息的默认值。
                return Proto()
            }
        }
    }
}
