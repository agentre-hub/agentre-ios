import CryptoKit
import Foundation
import Network

/// 测试进程里的一个真实 HTTP/1.1 服务端，只监听 127.0.0.1、端口由系统分配。
/// 模拟器与 Mac 共用回环地址，所以 App 连 `http://127.0.0.1:<port>` 就连到这里。
///
/// 同一个端口既答 REST，也接受 WebSocket 升级（中继 `/v1/relay/client`）：App 由服务器地址
/// 推出中继地址（同主机同端口、http → ws），真实服务端也是同一个端口。
/// 全部状态只在 `queue` 上读写。
final class LoopbackServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        var bearer: String? {
            guard let value = headers["authorization"], value.hasPrefix("Bearer ") else { return nil }
            return String(value.dropFirst("Bearer ".count))
        }
    }

    struct Response {
        var status: Int
        var body: Data
        var contentType = "application/json"
    }

    enum Outcome {
        case respond(Response)
        /// 升级成 WebSocket；交回的处理方从此收这条连接上的每一条二进制消息。
        case upgrade(any WebSocketHandler)
    }

    let queue = DispatchQueue(label: "agentre.uitests.loopback")
    private let listener: NWListener
    private let route: (Request) -> Outcome
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    /// 起监听并等它就绪；交回之后 `port` 即可用。
    init(route: @escaping (Request) -> Outcome) throws {
        self.route = route
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func stop() {
        // 先停止接收新连接，再关已有的：两步之间接进来的连接否则没人关。
        queue.sync {
            listener.cancel()
            for connection in connections.values { connection.close() }
            connections = [:]
        }
    }

    private func accept(_ connection: NWConnection) {
        let http = HTTPConnection(connection: connection, queue: queue, route: route) { [weak self] closed in
            self?.connections[ObjectIdentifier(closed)] = nil
        }
        connections[ObjectIdentifier(http)] = http
        http.start()
    }
}

/// 一条 WebSocket 连接上收发二进制消息的一方。回调都在服务端的 `queue` 上。
protocol WebSocketHandler: AnyObject {
    func opened(_ socket: WebSocketChannel)
    func received(_ message: Data, on socket: WebSocketChannel)
    func closed(_ socket: WebSocketChannel)
}

/// 已升级的一条连接：写二进制消息、或把它断掉（应用被挂起时系统收走的就是它）。
protocol WebSocketChannel: AnyObject {
    func send(_ message: Data)
    func drop()
}

/// 一条 TCP 连接：先按 HTTP/1.1 读请求（保活，可连着多条），升级后按 RFC 6455 读帧。
private final class HTTPConnection: WebSocketChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let route: (LoopbackServer.Request) -> LoopbackServer.Outcome
    private let onClose: (HTTPConnection) -> Void
    private var buffer = Data()
    private var socket: (any WebSocketHandler)?
    private var fragments = Data()
    private var isClosed = false

    init(
        connection: NWConnection, queue: DispatchQueue,
        route: @escaping (LoopbackServer.Request) -> LoopbackServer.Outcome,
        onClose: @escaping (HTTPConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.route = route
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        read()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        socket?.closed(self)
        socket = nil
        onClose(self)
    }

    // MARK: WebSocketChannel

    func send(_ message: Data) {
        guard !isClosed else { return }
        connection.send(content: Self.frame(opcode: 0x2, message), completion: .contentProcessed { _ in })
    }

    /// 先把已排队的帧发完再断：NWConnection.cancel 会丢掉还没发出去的数据（其中可能有关通道的空载荷帧）。
    func drop() {
        guard !isClosed else { return }
        connection.send(content: Self.frame(opcode: 0x8, Data()), completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    // MARK: 读

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if self.socket == nil { self.parseRequests() } else { self.parseFrames() }
            if isComplete || error != nil {
                self.close()
            } else if !self.isClosed {
                self.read()
            }
        }
    }

    private func parseRequests() {
        while socket == nil, !isClosed, let request = takeRequest() {
            handle(request)
        }
        if socket != nil { parseFrames() }
    }

    private func takeRequest() -> LoopbackServer.Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            close()
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
            close()
            return nil
        }
        let bodyStart = end.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        let target = URLComponents(string: String(requestLine[1]))
        let query = Dictionary(
            (target?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first }
        )
        return LoopbackServer.Request(
            method: String(requestLine[0]), path: target?.path ?? "/", query: query, headers: headers, body: body
        )
    }

    private func handle(_ request: LoopbackServer.Request) {
        switch route(request) {
        case .respond(let response):
            write(response)
        case .upgrade(let handler):
            guard request.headers["upgrade"]?.lowercased() == "websocket", let key = request.headers["sec-websocket-key"] else {
                write(LoopbackServer.Response(status: 400, body: Data()))
                return
            }
            let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            let accept = Data(digest).base64EncodedString()
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            socket = handler
            handler.opened(self)
        }
    }

    private func write(_ response: LoopbackServer.Response) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status)
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: keep-alive\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: WebSocket 帧（RFC 6455 §5）

    private func parseFrames() {
        while !isClosed, let (fin, opcode, payload) = takeFrame() {
            switch opcode {
            case 0x0, 0x1, 0x2:
                fragments.append(payload)
                guard fin else { continue }
                let message = fragments
                fragments = Data()
                socket?.received(message, on: self)
            case 0x8:
                connection.send(content: Self.frame(opcode: 0x8, Data()), completion: .contentProcessed { [weak self] _ in self?.close() })
            case 0x9:
                connection.send(content: Self.frame(opcode: 0xA, payload), completion: .contentProcessed { _ in })
            default:
                continue
            }
        }
    }

    private func takeFrame() -> (Bool, UInt8, Data)? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var index = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            index = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            // 最高位置位的 64 位长度转成 Int 是负数：按坏帧处理，不去切一个倒置的区间。
            let wide = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard wide <= UInt64(Int32.max) else { return nil }
            length = Int(wide)
            index = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= index + 4 else { return nil }
            mask = Array(bytes[index..<index + 4])
            index += 4
        }
        guard bytes.count >= index + length else { return nil }
        var payload = Array(bytes[index..<index + length])
        if masked {
            for offset in payload.indices { payload[offset] ^= mask[offset % 4] }
        }
        buffer = Data(bytes[(index + length)...])
        return (fin, opcode, Data(payload))
    }

    /// 服务端发出的帧不加掩码。
    private static func frame(opcode: UInt8, _ payload: Data) -> Data {
        var data = Data([0x80 | opcode])
        switch payload.count {
        case ..<126:
            data.append(UInt8(payload.count))
        case ..<65_536:
            data.append(126)
            data.append(UInt8(payload.count >> 8))
            data.append(UInt8(payload.count & 0xFF))
        default:
            data.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        data.append(payload)
        return data
    }
}
