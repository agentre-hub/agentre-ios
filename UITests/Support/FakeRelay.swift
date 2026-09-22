import AgentreWire
import Foundation
import SwiftProtobuf

/// 伪中继 `/v1/relay/client`：一条 WebSocket 上按信封多路复用虚拟通道。
///
/// - 信封 = 2 字节大端通道 ID 长度 + UTF-8 通道 ID + 载荷（agentre/pkg/wire/relayenvelope）；
///   空载荷 = 这条通道关了。
/// - 通道号由客户端自选；未知号上的第一个非空帧是目标声明（relay_ctr/channel.go 的 openChannel）。
///   本伪中继只认 `machine:<指纹>`，目标不认得即以空载荷关掉那一条。
/// - 其后每一帧是一条 wire `RpcFrame`，交给那台伪机器（`FakeAgentred`）作答。
///
/// 一切回调都在服务端的 `queue` 上。
final class FakeRelay: @unchecked Sendable {
    let machines: [FakeAgentred]
    private var isLiveToken: (String) -> Bool = { _ in false }
    private var clients: [RelayClient] = []
    /// 至今接受过几次中继升级（回到前台后重拨即 +1）。
    private(set) var upgrades = 0

    init(machines: [FakeAgentred]) {
        self.machines = machines
    }

    func attach(queue: DispatchQueue, validToken: @escaping (String) -> Bool) {
        isLiveToken = validToken
        for machine in machines { machine.queue = queue }
    }

    func client(for phoneFingerprint: String) -> RelayClient {
        let client = RelayClient(relay: self, phoneFingerprint: phoneFingerprint)
        clients.append(client)
        return client
    }

    /// 断开全部中继连接：应用被系统挂起时它那条 socket 就是这样没的。
    func dropAll() {
        let open = clients
        clients = []
        for client in open { client.socket?.drop() }
    }

    /// 服务端判死通往 `machine` 的每条通道：各发一帧空载荷（relay_ctr 关通道的写法），连接本身不动。
    func closeChannels(to machine: FakeAgentred) {
        for client in clients { client.closeChannels(to: machine) }
    }

    /// 真的升级成了 WebSocket 才算一次拨号（没带升级头的请求在握手前就被 400 挡回）。
    fileprivate func upgraded() { upgrades += 1 }

    fileprivate func forget(_ client: RelayClient) {
        clients.removeAll { $0 === client }
    }

    fileprivate func machine(for target: String) -> FakeAgentred? {
        machines.first { "machine:\($0.fingerprint)" == target }
    }

    fileprivate func accepts(_ credential: String) -> Bool { isLiveToken(credential) }
}

/// 一条客户端中继连接上的通道注册表。
final class RelayClient: WebSocketHandler {
    private unowned let relay: FakeRelay
    let phoneFingerprint: String
    fileprivate weak var socket: (any WebSocketChannel)?
    private var channels: [String: RelayPeer] = [:]

    fileprivate init(relay: FakeRelay, phoneFingerprint: String) {
        self.relay = relay
        self.phoneFingerprint = phoneFingerprint
    }

    func opened(_ socket: any WebSocketChannel) {
        self.socket = socket
        relay.upgraded()
    }

    func received(_ message: Data, on socket: any WebSocketChannel) {
        guard let (channelID, payload) = Self.unwrap(message) else { return }
        if payload.isEmpty {
            channels.removeValue(forKey: channelID)?.close()
            return
        }
        if let peer = channels[channelID] {
            peer.receive(payload)
            return
        }
        let target = String(decoding: payload, as: UTF8.self)
        guard let machine = relay.machine(for: target) else {
            send(channelID, Data())
            return
        }
        channels[channelID] = RelayPeer(client: self, channelID: channelID, machine: machine) { [unowned relay] in relay.accepts($0) }
    }

    fileprivate func closeChannels(to machine: FakeAgentred) {
        for (channelID, peer) in channels where peer.machine === machine {
            channels[channelID] = nil
            peer.close()
            send(channelID, Data())
        }
    }

    func closed(_ socket: any WebSocketChannel) {
        for peer in channels.values { peer.close() }
        channels = [:]
        relay.forget(self)
    }

    fileprivate func send(_ channelID: String, _ payload: Data) {
        socket?.send(Self.wrap(channelID, payload))
    }

    static func wrap(_ channelID: String, _ payload: Data) -> Data {
        let id = Data(channelID.utf8)
        var data = Data([UInt8(id.count >> 8), UInt8(id.count & 0xFF)])
        data.append(id)
        data.append(payload)
        return data
    }

    static func unwrap(_ envelope: Data) -> (String, Data)? {
        let bytes = [UInt8](envelope)
        guard bytes.count >= 2 else { return nil }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, length <= 128, bytes.count >= 2 + length,
              let id = String(validating: bytes[2..<2 + length], as: UTF8.self)
        else { return nil }
        return (id, Data(bytes[(2 + length)...]))
    }
}

/// 通道那一头的对端（agentred 眼里的一个 peer）：先 auth.account 握手，再收 RPC。
final class RelayPeer: Hashable {
    private unowned let client: RelayClient
    let channelID: String
    fileprivate let machine: FakeAgentred
    private let accepts: (String) -> Bool
    private(set) var authenticated = false
    private(set) var isClosed = false

    fileprivate init(client: RelayClient, channelID: String, machine: FakeAgentred, accepts: @escaping (String) -> Bool) {
        self.client = client
        self.channelID = channelID
        self.machine = machine
        self.accepts = accepts
    }

    /// 这条通道对端的设备身份：中继按令牌认出的那台手机。
    var fingerprint: String { client.phoneFingerprint }

    func receive(_ payload: Data) {
        guard let frame = try? Agentre_Wire_RpcFrame(serializedBytes: payload), case .request(let request)? = frame.body else { return }
        let method = Agentre_Wire_RpcMethod(rawValue: Int(request.methodID)) ?? .unspecified
        let reply: FakeAgentred.Reply
        if method == .authAccount {
            reply = handshake(request.encodedPayload)
        } else if !authenticated {
            reply = .error(-32001, "unauthorized")
        } else {
            reply = machine.answer(method, request.encodedPayload, from: self)
        }
        var out = Agentre_Wire_RpcFrame()
        out.id = frame.id
        switch reply {
        case .result(let message):
            var response = Agentre_Wire_Response()
            response.methodID = request.methodID
            response.encodedPayload = (try? message.serializedData()) ?? Data()
            out.response = response
        case .error(let code, let text):
            var error = Agentre_Wire_RpcError()
            error.code = code
            error.message = text
            out.error = error
        }
        send(out)
    }

    /// 按 agentred 的握手：凭据是账号设备令牌，协议版本逐字相等才放行。
    private func handshake(_ payload: Data) -> FakeAgentred.Reply {
        guard let request = try? Agentre_Wire_AuthAccountRequest(serializedBytes: payload), accepts(request.credential) else {
            return .error(-32001, "unauthorized")
        }
        guard request.protocolVersion == FakeAgentred.protocolVersion else { return .error(-32006, "protocol version mismatch") }
        authenticated = true
        var response = Agentre_Wire_AuthAccountResponse()
        response.ok = true
        response.protocolVersion = FakeAgentred.protocolVersion
        response.minSupportedProtocolVersion = FakeAgentred.protocolVersion
        response.peerFingerprint = machine.fingerprint
        response.daemonVersion = "0.1.0"
        return .result(response)
    }

    func push(_ notification: Agentre_Wire_RpcNotification) {
        var frame = Agentre_Wire_RpcFrame()
        frame.notification = notification
        send(frame)
    }

    private func send(_ frame: Agentre_Wire_RpcFrame) {
        guard !isClosed, let bytes = try? frame.serializedData() else { return }
        client.send(channelID, bytes)
    }

    fileprivate func close() {
        isClosed = true
        machine.forget(self)
    }

    static func == (lhs: RelayPeer, rhs: RelayPeer) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
