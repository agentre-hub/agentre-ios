import AgentreDomain
import Foundation

/// 账号级中继连接：一个账号任一时刻只持有一条物理 WebSocket，其上多路复用若干虚拟通道。
///
/// 每条通道开通时的第一帧声明自己的目标（`conversation:<id>` / `machine:<fingerprint>`），
/// 所以同一条连接上的两条通道可以落在两台不同的机器上。通道号由本端在自己这条连接的
/// 命名空间里自选（`c<n>`），服务端负责翻译；保留前缀 `~` 归服务端，本端只收不写。
///
/// 连接断开后按指数退让、封顶、带抖动重拨；连上后逐条重新声明目标，再由各通道自己
/// 重做握手与补齐。
public actor RelayConnection {
    public nonisolated let signals: AsyncStream<RelaySignal>
    private let signalSink: AsyncStream<RelaySignal>.Continuation

    private let url: URL
    private let dialer: any RelaySocketDialing
    private let accessToken: @Sendable () async throws -> String
    private let sleeper: any Sleeping
    private let random: @Sendable () -> Double
    private let backoff: RelayBackoff

    private var socket: (any RelaySocket)?
    private var channels: [String: RelayChannel] = [:]
    private var order: [String] = []
    private var byTarget: [RelayTarget: String] = [:]
    /// 在当前这条物理连接上已经声明过目标的通道。
    private var declared: Set<String> = []
    /// 因协议版本不等而停下的通道，按目标记着：同一个对端不会自己变新，再要这个目标拿到的
    /// 仍是这一条（状态 `.updateRequired`、调用即抛），不开新通道、不再握手。登出时随连接清掉。
    private var halted: [RelayTarget: RelayChannel] = [:]
    private var nextChannelNumber = 1
    private var runner: Task<Void, Never>?
    private var stopped = false
    /// 连着连不上了几次；重拨按它退让。拨号本身成功不算连上（URLSession 的拨号不等升级完成，
    /// 服务端拒了升级也照样「拨通」），收到对端的第一帧才归零。
    private var failures = 0

    public init(
        url: URL,
        dialer: any RelaySocketDialing,
        accessToken: @escaping @Sendable () async throws -> String,
        sleeper: any Sleeping,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        backoff: RelayBackoff = .standard
    ) {
        self.url = url
        self.dialer = dialer
        self.accessToken = accessToken
        self.sleeper = sleeper
        self.random = random
        self.backoff = backoff
        // 没人读时只留最近的一段：信号那一路是账号级的推送，不能在内存里无限攒下去。
        (signals, signalSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    /// 开始拨号并保持连接（断线自动重拨）。
    public func start() {
        guard runner == nil else { return }
        stopped = false
        runner = Task { await self.run() }
    }

    /// 关闭整条连接（登出），不再重拨；全部通道随之关闭。
    public func stop() async {
        stopped = true
        runner?.cancel()
        runner = nil
        socket?.close()
        socket = nil
        declared = []
        let all = order.compactMap { channels[$0] }
        channels = [:]
        order = []
        byTarget = [:]
        halted = [:]
        for channel in all { await channel.shutdown() }
        signalSink.yield(.closed)
    }

    /// 取某个目标的通道；同一目标只有一条。连接已就绪时当场声明目标并开始握手。
    public func channel(for target: RelayTarget) async -> RelayChannel {
        if let stopped = halted[target] { return stopped }
        if let id = byTarget[target], let existing = channels[id] { return existing }
        let id = "c\(nextChannelNumber)"
        nextChannelNumber += 1
        let channel = RelayChannel(
            id: id, target: target, connection: self,
            accessToken: accessToken, sleeper: sleeper, random: random, backoff: backoff
        )
        channels[id] = channel
        order.append(id)
        byTarget[target] = id
        if socket != nil {
            await declare(id)
            await channel.opened()
        }
        return channel
    }

    // MARK: 通道回调

    /// 通道往自己那一路写一帧。
    func write(_ channelID: String, _ payload: Data) async throws {
        guard channels[channelID] != nil else { throw RelayCallError.channelClosed }
        guard let socket else { throw RelayCallError.disconnected }
        await declare(channelID)
        do {
            try await socket.send(RelayEnvelope.wrap(channelID: channelID, payload: payload))
        } catch {
            throw RelayCallError.disconnected
        }
    }

    /// 通道因协议版本不等停下：像关闭一样摘掉并告诉对端，但记住它的目标，此后不再为它开新通道。
    func halt(_ channelID: String) async {
        guard let channel = channels[channelID] else { return }
        halted[channel.target] = channel
        await close(channelID)
    }

    /// 通道自己不再使用：从注册表摘掉，并以空载荷告诉对端这条通道关了。
    func close(_ channelID: String) async {
        guard let channel = channels.removeValue(forKey: channelID) else { return }
        order.removeAll { $0 == channelID }
        byTarget[channel.target] = nil
        guard declared.remove(channelID) != nil, let socket else { return }
        try? await socket.send(RelayEnvelope.wrap(channelID: channelID, payload: Data()))
    }

    // MARK: 连接循环

    private func run() async {
        while !Task.isCancelled {
            if let socket = await dialOnce() {
                // 拨号在途时登出了：拨回来的连接带着已登出账号的令牌，当场关掉，不接管。
                guard !Task.isCancelled, !stopped else {
                    socket.close()
                    return
                }
                await adopt(socket)
                await read(socket)
                await lose(socket)
            }
            guard !Task.isCancelled, !stopped else { return }
            let delay = backoff.delay(afterFailures: failures, random: random())
            failures += 1
            do { try await sleeper.sleep(for: delay) } catch { return }
        }
    }

    private func dialOnce() async -> (any RelaySocket)? {
        do {
            let token = try await accessToken()
            return try await dialer.dial(url: url, accessToken: token)
        } catch {
            return nil
        }
    }

    private func adopt(_ socket: any RelaySocket) async {
        self.socket = socket
        declared = []
        // 新连接上服务端认不得旧通道：先逐条声明目标（它必须是通道的第一帧），再让
        // 每条通道自己重做握手。
        for id in order { await declare(id) }
        for id in order { await channels[id]?.opened() }
    }

    private func read(_ socket: any RelaySocket) async {
        while let frame = try? await socket.receive() {
            failures = 0
            await dispatch(frame)
        }
    }

    private func lose(_ lost: any RelaySocket) async {
        lost.close()
        socket = nil
        declared = []
        guard !stopped else { return }
        signalSink.yield(.closed)
        for id in order { await channels[id]?.connectionLost() }
    }

    private func declare(_ channelID: String) async {
        guard let socket, let channel = channels[channelID], !declared.contains(channelID) else { return }
        declared.insert(channelID)
        let declaration = Data(channel.target.declaration.utf8)
        try? await socket.send(RelayEnvelope.wrap(channelID: channelID, payload: declaration))
    }

    private func dispatch(_ frame: Data) async {
        // 单帧坏掉不影响连接：丢掉，继续等下一帧。
        guard let (channelID, payload) = try? RelayEnvelope.unwrap(frame) else { return }
        if channelID == RelayProtocol.signalChannelID {
            signalSink.yield(payload.isEmpty ? .closed : .frame(payload))
            return
        }
        guard let channel = channels[channelID] else { return }
        if payload.isEmpty {
            // 服务端判死了这一条；同一连接上的其它通道照常。
            channels[channelID] = nil
            order.removeAll { $0 == channelID }
            byTarget[channel.target] = nil
            declared.remove(channelID)
            await channel.shutdown()
            return
        }
        await channel.receive(payload)
    }
}
