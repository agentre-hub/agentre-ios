import AgentreDomain
import AgentreWire
import Foundation
import SwiftData

/// 一帧来自中继的通知，带着它的载体字段。实时帧与补齐拉回的帧都是这个形状
/// （与中继层交出的 `RelayNotification` 逐字段对应）。
public struct IncomingFrame: Sendable {
    public var conversationID: String?
    /// 持久帧的序号；预览帧与不属于对话的通知为 nil。
    public var seq: Int64?
    /// 源端时钟上的发生时刻（Unix 毫秒）；只有补齐拉回的帧才带。
    public var createtime: Int64?
    public var payload: Agentre_Wire_RpcNotification

    public init(conversationID: String?, seq: Int64?, createtime: Int64?, payload: Agentre_Wire_RpcNotification) {
        self.conversationID = conversationID
        self.seq = seq
        self.createtime = createtime
        self.payload = payload
    }
}

/// 手机自有的会话库（SwiftData，落在应用沙盒里的一个库文件上）。
///
/// 与服务端 `mirror_svc` 同构：认领（`save`）→ attach → pull → 落自己的库。规则逐条对照它：
///
/// - 只收保存过的会话：不认识的会话一帧都不落，删掉之后到达的帧也不写回。
/// - 帧按 (发起端, 会话, seq) 唯一，重复到达时先到的那一行为准。
/// - 预览帧与不带号的帧不进转录。
/// - 发生时刻原样取自载体：补齐拉回的照录（0 仍是 0），实时帧盖收帧那一刻。
/// - 游标是本机自己的——已落库的最大帧号，不是机器报的高水位。
///
/// 实时帧与补齐帧只有 `record` 这一个入口。
public actor LocalConversationStore: ConversationStore, ModelActor {
    public static let fileName = "Conversations.store"
    static let schema = Schema([ConversationRecord.self, FrameRecord.self])

    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor
    private let now: @Sendable () -> Int64

    /// 打开（或建立）`directory` 下的库文件。
    public init(
        directory: URL,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) throws {
        let configuration = ModelConfiguration(
            schema: Self.schema, url: directory.appending(path: Self.fileName), cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: Self.schema, configurations: configuration)
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
        self.now = now
    }

    // MARK: 写入（认得 wire 的一侧）

    /// 保存一条会话（或以机器最新的清单刷新它）。本机的游标与已读位不受清单影响。
    @discardableResult
    public func save(_ summary: Agentre_Wire_SessionSummary, via machineFingerprint: String) throws -> ConversationKey {
        let owner = summary.peerFingerprint.isEmpty ? machineFingerprint : summary.peerFingerprint
        let key = ConversationKey(machineFingerprint: owner, conversationID: summary.conversationID)
        let row: ConversationRecord
        if let existing = try fetchConversation(key) {
            row = existing
        } else {
            row = ConversationRecord(
                machineFingerprint: owner, conversationID: summary.conversationID, viaFingerprint: machineFingerprint
            )
            modelContext.insert(row)
        }
        row.viaFingerprint = machineFingerprint
        row.peerFingerprint = summary.peerFingerprint
        row.title = summary.title
        row.agentSyncID = summary.agentSyncID
        row.cwd = summary.cwd
        row.projectSyncID = summary.projectSyncID
        row.backendType = summary.backendType
        row.lifecycleState = summary.lifecycleState
        row.waitingForInput = summary.waitingForInput
        row.lastMessageAt = summary.lastMessageAt
        try modelContext.save()
        return key
    }

    /// 让经 `machineFingerprint` 那台机器到达的一批帧落库。实时帧与补齐帧都走这里。
    public func record(_ frames: [IncomingFrame], via machineFingerprint: String) throws {
        var batches: [String: [IncomingFrame]] = [:]
        var order: [String] = []
        for frame in frames {
            guard let seq = frame.seq, seq > 0, !frame.payload.isPreview,
                  let conversationID = frame.conversationID ?? frame.payload.durableConversationID
            else { continue }
            if batches[conversationID] == nil { order.append(conversationID) }
            batches[conversationID, default: []].append(frame)
        }
        for conversationID in order {
            guard let row = try fetchConversation(conversationID, via: machineFingerprint) else { continue }
            try append(batches[conversationID] ?? [], to: row)
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    /// 跟着一条帧流落库，直到它结束。App 把中继通道交出的通知接到这里。
    public func follow<Frames: AsyncSequence & Sendable>(
        _ frames: Frames, via machineFingerprint: String
    ) async throws where Frames.Element == IncomingFrame {
        for try await frame in frames {
            try record([frame], via: machineFingerprint)
        }
    }

    // MARK: ConversationStore

    public func conversations() throws -> [SavedConversation] {
        let descriptor = FetchDescriptor<ConversationRecord>(sortBy: [
            SortDescriptor(\.lastMessageAt, order: .reverse), SortDescriptor(\.conversationID),
        ])
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    public func conversation(_ key: ConversationKey) throws -> SavedConversation? {
        try fetchConversation(key)?.snapshot
    }

    public func transcript(_ key: ConversationKey) throws -> [TranscriptFrame] {
        let owner = key.machineFingerprint
        let id = key.conversationID
        let descriptor = FetchDescriptor<FrameRecord>(
            predicate: #Predicate { $0.machineFingerprint == owner && $0.conversationID == id },
            sortBy: [SortDescriptor(\.seq)]
        )
        return try modelContext.fetch(descriptor).map {
            TranscriptFrame(seq: $0.seq, createtime: $0.createtime, payload: $0.payload)
        }
    }

    public func latestSeq(_ key: ConversationKey) throws -> Int64 {
        try fetchConversation(key)?.latestSeq ?? 0
    }

    public func markRead(_ key: ConversationKey) throws {
        guard let row = try fetchConversation(key) else { return }
        row.readMarker = row.lastMessageAt
        try modelContext.save()
    }

    public func delete(_ key: ConversationKey) throws {
        let owner = key.machineFingerprint
        let id = key.conversationID
        try modelContext.delete(
            model: FrameRecord.self,
            where: #Predicate { $0.machineFingerprint == owner && $0.conversationID == id }
        )
        try modelContext.delete(
            model: ConversationRecord.self,
            where: #Predicate { $0.machineFingerprint == owner && $0.conversationID == id }
        )
        try modelContext.save()
    }

    public func removeAll() throws {
        try modelContext.delete(model: FrameRecord.self)
        try modelContext.delete(model: ConversationRecord.self)
        try modelContext.save()
    }

    // MARK: 内部

    /// 追加一条会话的一批帧：库里已有的号与同批里重复的号都跳过，先到的为准。
    private func append(_ frames: [IncomingFrame], to row: ConversationRecord) throws {
        let owner = row.machineFingerprint
        let id = row.conversationID
        let seqs = frames.compactMap(\.seq)
        let stored = try modelContext.fetch(FetchDescriptor<FrameRecord>(
            predicate: #Predicate { $0.machineFingerprint == owner && $0.conversationID == id && seqs.contains($0.seq) }
        ))
        var seen = Set(stored.map(\.seq))
        for frame in frames {
            guard let seq = frame.seq, seen.insert(seq).inserted else { continue }
            var payload = frame.payload
            payload.stamp(seq: seq)
            modelContext.insert(FrameRecord(
                machineFingerprint: owner, conversationID: id, seq: seq,
                createtime: frame.createtime ?? now(), payload: try payload.serializedData()
            ))
            row.latestSeq = max(row.latestSeq, seq)
        }
    }

    private func fetchConversation(_ key: ConversationKey) throws -> ConversationRecord? {
        let owner = key.machineFingerprint
        let id = key.conversationID
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.machineFingerprint == owner && $0.conversationID == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchConversation(_ id: String, via machineFingerprint: String) throws -> ConversationRecord? {
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.viaFingerprint == machineFingerprint && $0.conversationID == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func rowCounts() throws -> (conversations: Int, frames: Int) {
        (
            try modelContext.fetchCount(FetchDescriptor<ConversationRecord>()),
            try modelContext.fetchCount(FetchDescriptor<FrameRecord>())
        )
    }
}

private extension ConversationRecord {
    var snapshot: SavedConversation {
        SavedConversation(
            key: ConversationKey(machineFingerprint: machineFingerprint, conversationID: conversationID),
            peerFingerprint: peerFingerprint,
            title: title,
            agentSyncID: agentSyncID,
            cwd: cwd,
            projectSyncID: projectSyncID,
            backendType: backendType,
            lifecycleState: lifecycleState,
            waitingForInput: waitingForInput,
            lastMessageAt: lastMessageAt,
            latestSeq: latestSeq,
            readMarker: readMarker
        )
    }
}
