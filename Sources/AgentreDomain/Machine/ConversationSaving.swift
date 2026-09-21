import Foundation

/// 补齐拉回的一帧持久帧。载荷是 wire `RpcNotification` 的 protobuf 字节：领域层不解码它。
public struct PulledFrame: Sendable, Equatable {
    public let seq: Int64
    /// 源端时钟上的发生时刻（Unix 毫秒）；0 表示机器没报。
    public let createtime: Int64
    public let payload: Data

    public init(seq: Int64, createtime: Int64, payload: Data) {
        self.seq = seq
        self.createtime = createtime
        self.payload = payload
    }
}

/// `sessionPull` 的一批。
public struct PulledFrames: Sendable, Equatable {
    public let frames: [PulledFrame]
    /// 下一批从这里之后接着拉。
    public let cursor: Int64
    public let hasMore: Bool

    public init(frames: [PulledFrame], cursor: Int64, hasMore: Bool) {
        self.frames = frames
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

/// 经中继认领一条会话并取它的转录（通道 `machine:<指纹>`，RPC 以 conversation_id 指明对话）。
/// 适配器在装配层实现。
public protocol MachineSessionTransfer: Sendable {
    /// attach：认领这条会话，此后它的实时帧经这台机器送来。答复机器上的最大帧号。
    func attach(conversationID: String, peerFingerprint: String, on machineFingerprint: String) async throws -> Int64
    /// pull：取 `cursor` 之后的一批持久帧。
    func pull(conversationID: String, peerFingerprint: String, after cursor: Int64, on machineFingerprint: String) async throws -> PulledFrames
}

/// 本地库的写入一侧（实现层认得 wire，把领域形状转成它自己的）。
public protocol ConversationSaving: ConversationStore {
    /// 把机器清单里的一条收进本地库（已在库里则以它刷新摘要）。
    @discardableResult
    func save(_ session: MachineSession, via machineFingerprint: String) async throws -> ConversationKey
    /// 让一批拉回的帧落进 `key` 那条会话。
    func record(_ frames: [PulledFrame], into key: ConversationKey, via machineFingerprint: String) async throws
}

/// 保存到手机（规格决策 15 / 16）：收进本地库，attach，再从本机已有的最大帧号起按游标 pull 到底。
/// 半途失败则把这一次新收进来的那条撤掉——没拉全的会话不假装已经在手机上。
public struct ConversationSaver: Sendable {
    public enum Failure: Error, Equatable {
        /// 机器说还有，游标却没往前走。
        case stalledPull
        /// 机器不在线：拉取要它来答。
        case machineOffline
    }

    private let store: any ConversationSaving
    private let transfer: any MachineSessionTransfer

    public init(store: any ConversationSaving, transfer: any MachineSessionTransfer) {
        self.store = store
        self.transfer = transfer
    }

    @discardableResult
    public func save(_ session: MachineSession, on machine: Machine) async throws -> ConversationKey {
        guard machine.online else { throw Failure.machineOffline }
        let wasSaved = try await store.conversation(machine.key(of: session)) != nil
        let key = try await store.save(session, via: machine.fingerprint)
        do {
            _ = try await transfer.attach(
                conversationID: session.conversationID, peerFingerprint: session.peerFingerprint, on: machine.fingerprint
            )
            var cursor = try await store.latestSeq(key)
            while true {
                let batch = try await transfer.pull(
                    conversationID: session.conversationID, peerFingerprint: session.peerFingerprint,
                    after: cursor, on: machine.fingerprint
                )
                try await store.record(batch.frames, into: key, via: machine.fingerprint)
                guard batch.hasMore else { break }
                guard batch.cursor > cursor else { throw Failure.stalledPull }
                cursor = batch.cursor
            }
        } catch {
            // 只撤掉这一次新收进来的；本来就在库里的保持原样，下次补齐从它已有的帧号接着拉。
            if !wasSaved { try? await store.delete(key) }
            throw error
        }
        return key
    }
}
