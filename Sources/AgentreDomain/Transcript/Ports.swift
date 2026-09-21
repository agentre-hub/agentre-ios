import Foundation

/// 把一帧 wire 通知（`RpcNotification` 的 protobuf 字节）解成转录事件。
/// 实现归认得 wire 的那一层；解不出（不属于转录、坏帧）时为 nil。
public protocol TranscriptPayloadDecoding: Sendable {
    func decode(_ payload: Data) -> DecodedNotification?
}

/// 实时到达的一帧。轮次边界与预览帧线上不带号：`seq` 为 nil。
public struct LiveTranscriptFrame: Sendable, Equatable {
    public var seq: Int64?
    /// 源端时钟上的发生时刻（Unix 毫秒）；0 = 不知道。
    public var createtime: Int64
    public var payload: Data

    public init(seq: Int64?, createtime: Int64, payload: Data) {
        self.seq = seq
        self.createtime = createtime
        self.payload = payload
    }
}

/// 一页向机器补拉的持久帧（SessionPullResponse）。
public struct TranscriptPage: Sendable, Equatable {
    /// seq 大于请求游标的帧，升序。
    public var frames: [TranscriptFrame]
    /// 下一页的游标（本页最后一帧的 seq）。
    public var cursor: Int64
    public var hasMore: Bool
    /// 机器上这条会话还留着的最早帧号；0 = 没报。
    public var oldestSeq: Int64

    public init(frames: [TranscriptFrame], cursor: Int64, hasMore: Bool, oldestSeq: Int64) {
        self.frames = frames
        self.cursor = cursor
        self.hasMore = hasMore
        self.oldestSeq = oldestSeq
    }
}

/// 转录需要走中继的两件事：向承载会话的机器补拉历史（session.pull），与接上实时帧
/// （session.attach 之后的帧投递）。不读服务端的转录端点。适配器归装配层。
public protocol TranscriptRelay: Sendable {
    /// 拉 seq 大于 `cursor` 的持久帧，最多 `limit` 条，升序。
    func pull(_ key: ConversationKey, peerFingerprint: String, cursor: Int64, limit: Int) async throws -> TranscriptPage
    /// 接上这条会话的实时帧。流在通道关闭时结束。
    func attach(_ key: ConversationKey, peerFingerprint: String) async throws -> AsyncStream<LiveTranscriptFrame>
}
