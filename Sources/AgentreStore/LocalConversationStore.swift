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

    /// 实时到达的帧（含补齐期间缓冲下来的实时帧）：载体上没有发生时刻。
    /// 只有它们跟随摘要——补齐拉回的是历史，摘要由机器的清单快照说了算。
    var isLive: Bool { createtime == nil }
}

/// 跟随一条已保存会话要的三样：会话键、带给机器的发起端指纹、经哪台机器走。
public struct FollowTarget: Sendable, Equatable {
    public let key: ConversationKey
    public let peerFingerprint: String
    public let carrier: String
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
/// - 实时帧让摘要跟着走（`follow`）：轮次边界改生命周期与最后活动，审批 / 提问的
///   请求与落定改「等你处理」。与帧号正交——线上的轮次边界帧不带号，照样跟随。
///
/// 实时帧与补齐帧只有 `record` 这一个入口。
public actor LocalConversationStore: ConversationSettingsRecording {
    public static let fileName = "Conversations.store"
    static let schema = Schema([ConversationRecord.self, FrameRecord.self])

    private let directory: URL
    /// 库文件的上下文（它持有自己的容器）。删库文件重开时整个换掉。
    private var modelContext: ModelContext
    let now: @Sendable () -> Int64
    /// 退出登录时删掉全部行的那一步。只有测试会换掉它（模拟删不掉）。
    private let clearRows: @Sendable (ModelContext) throws -> Void
    /// 从实时帧上看见、此刻还没落定的待决请求标识（mirror_svc 的 trackedSession.waiters）。
    /// 没有条目 = 帧还没就「等你处理」说过话，清单快照仍是权威；空集合 = 帧说过话，此刻一个待决都没有。
    /// 待决是机器进程内、按轮的，所以这张表只在内存里：冷启动后重新由快照说了算。
    private var waiters: [ConversationKey: Set<String>] = [:]
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// 打开（或建立）`directory` 下的库文件。
    public init(
        directory: URL,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) throws {
        try self.init(directory: directory, now: now, clearRows: Self.deleteAllRows)
    }

    init(
        directory: URL,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        clearRows: @escaping @Sendable (ModelContext) throws -> Void
    ) throws {
        self.directory = directory
        modelContext = ModelContext(try Self.openContainer(in: directory))
        self.now = now
        self.clearRows = clearRows
    }

    private static func openContainer(in directory: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema, url: directory.appending(path: fileName), cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    // MARK: 写入（认得 wire 的一侧）

    /// 保存一条会话（或以机器最新的清单刷新它）。本机的游标与已读位不受清单影响。
    @discardableResult
    public func save(_ summary: Agentre_Wire_SessionSummary, via machineFingerprint: String) throws -> ConversationKey {
        let key = ConversationKey(conversationID: summary.conversationID, peerFingerprint: summary.peerFingerprint, via: machineFingerprint)
        let owner = key.machineFingerprint
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
        // 与跟随帧同一条规矩：只前移不倒退。边界帧取的是本机钟，钟慢的机器报来的较早时刻不能把它拉回去。
        row.lastMessageAt = max(row.lastMessageAt, summary.lastMessageAt)
        row.providerKey = summary.providerKey
        row.modelKey = summary.modelKey
        row.reasoningEffort = summary.reasoningEffort
        // 新快照是机器此刻的原话，比从帧上攒出来的新：待决集合作废（mirror_svc 的 setSummary）。
        waiters[key] = nil
        try commit()
        return key
    }

    /// 让经 `machineFingerprint` 那台机器到达的一批帧落库。实时帧与补齐帧都走这里。
    public func record(_ frames: [IncomingFrame], via machineFingerprint: String) throws {
        var batches: [String: [IncomingFrame]] = [:]
        var order: [String] = []
        for frame in frames {
            guard !frame.payload.isPreview,
                  let conversationID = frame.conversationID ?? frame.payload.durableConversationID
            else { continue }
            if batches[conversationID] == nil { order.append(conversationID) }
            batches[conversationID, default: []].append(frame)
        }
        for conversationID in order {
            guard let row = try fetchConversation(conversationID, via: machineFingerprint) else { continue }
            try apply(batches[conversationID] ?? [], to: row)
        }
        try commit()
    }

    /// 让一批已知属于 `key` 那条会话的帧落库（补拉：会话键在手）。同一台承载机上可以有两条
    /// 同号会话（它自己的与它代转的他端的），按会话键认行，不按承载机 + 会话号猜。
    func record(_ frames: [IncomingFrame], into key: ConversationKey) throws {
        guard let row = try fetchConversation(key) else { return }
        try apply(frames.filter { !$0.payload.isPreview }, to: row)
        try commit()
    }

    /// 全部已保存会话的跟随目标。只读摘要行，不解帧——库每变一次都要问一遍。
    public func followTargets() throws -> [FollowTarget] {
        try modelContext.fetch(FetchDescriptor<ConversationRecord>()).map {
            FollowTarget(key: $0.key, peerFingerprint: $0.peerFingerprint, carrier: $0.viaFingerprint)
        }
    }

    // MARK: ConversationStore

    public func conversations() throws -> [SavedConversation] {
        let descriptor = FetchDescriptor<ConversationRecord>(sortBy: [
            SortDescriptor(\.lastMessageAt, order: .reverse), SortDescriptor(\.conversationID),
        ])
        return try modelContext.fetch(descriptor).map(snapshot)
    }

    public func conversation(_ key: ConversationKey) throws -> SavedConversation? {
        try fetchConversation(key).map(snapshot)
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

    /// 这条会话经哪台机器保存、跟随的（承载机）。会话键里的是发起端，二者不可互相代替：
    /// 打开、补齐、回应审批都走承载机的 `machine:` 通道。不在库里时为 nil。
    public func carrier(of key: ConversationKey) throws -> String? {
        try fetchConversation(key)?.viaFingerprint
    }

    /// attach 报来的机器最高帧号低于本机游标：那边的帧号重新起算了（整条会话被删、会话号被复用）。
    /// 在同一步里把旧编号下落过的帧整段丢掉、游标归零（mirror_svc.dropCursorAboveHighWater）——
    /// 重拉的帧与旧帧落在同一个 (发起端, 会话, seq) 上，旧行不走就会把新帧当重复挡掉，
    /// 而低于最高帧号的那几行同样属于旧编号。摘要与已读位不动。交回是否回退了。
    @discardableResult
    public func rewind(_ key: ConversationKey, highWater: Int64) throws -> Bool {
        guard let row = try fetchConversation(key), row.latestSeq > highWater else { return false }
        let owner = key.machineFingerprint
        let id = key.conversationID
        try modelContext.delete(
            model: FrameRecord.self,
            where: #Predicate { $0.machineFingerprint == owner && $0.conversationID == id }
        )
        row.latestSeq = 0
        waiters[key] = nil
        try commit(force: true)
        return true
    }

    public func markRead(_ key: ConversationKey) throws {
        guard let row = try fetchConversation(key) else { return }
        row.readMarker = row.lastMessageAt
        try commit()
    }

    public func recordModelTarget(_ key: ConversationKey, providerKey: String, modelKey: String) throws {
        guard let row = try fetchConversation(key) else { return }
        row.providerKey = providerKey
        row.modelKey = modelKey
        try commit()
    }

    public func recordReasoningEffort(_ key: ConversationKey, effort: String) throws {
        guard let row = try fetchConversation(key) else { return }
        row.reasoningEffort = effort
        try commit()
    }

    public func delete(_ key: ConversationKey) throws {
        waiters[key] = nil
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
        try commit(force: true)
    }

    /// 行删不掉时退到删库文件：库里只有上一个账号的会话，没有别的要留，
    /// 把库文件连同日志一起删掉、在原处重开一个空库，此后本实例与冷启动都读不到那些行。
    public func removeAll() throws {
        waiters.removeAll()
        do {
            try clearRows(modelContext)
            try commit(force: true)
        } catch {
            modelContext.rollback()
            try recreate()
            notifyObservers()
        }
    }

    private static func deleteAllRows(_ context: ModelContext) throws {
        try context.delete(model: FrameRecord.self)
        try context.delete(model: ConversationRecord.self)
    }

    /// 删掉库文件（主文件、-wal、-shm 与外置数据目录）并在原处重开一个空库。
    private func recreate() throws {
        let stem = (Self.fileName as NSString).deletingPathExtension
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(Self.fileName) || $0.lastPathComponent == ".\(stem)_SUPPORT" }
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
        modelContext = ModelContext(try Self.openContainer(in: directory))
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopObserving(id) }
        }
        return stream
    }

    // MARK: 内部

    /// 落盘并通知订阅者。批量删除不经变更跟踪，`hasChanges` 看不见它们，所以删除路径强制提交。
    private func commit(force: Bool = false) throws {
        guard force || modelContext.hasChanges else { return }
        try modelContext.save()
        notifyObservers()
    }

    private func notifyObservers() {
        for observer in observers.values { observer.yield() }
    }

    private func stopObserving(_ id: UUID) {
        observers[id] = nil
    }

    /// 一行摘要连同列表要的两样预览：此刻等你处理的那件事，与最后一句话。
    private func snapshot(_ row: ConversationRecord) throws -> SavedConversation {
        var conversation = row.snapshot
        let preview = try preview(of: row)
        conversation.pending = preview.pending
        conversation.pendingCount = preview.pendingCount
        conversation.lastText = preview.lastText
        return conversation
    }

    /// 从最新的帧往回找，最多看 `previewWindow` 帧：等你处理时，对端停在那次请求上，
    /// 它就在转录末尾附近；数尚未处理的请求条数同样只看这一段窗口。
    static let previewWindow = 200

    /// 待决取最近一次没有落定的审批 / 提问请求，与这一行尚未处理的请求条数，只在正等你处理时才取——
    /// 等待与否由摘要说了算（跟随规则），帧只回答「等的是什么、有几件」。
    private func preview(of row: ConversationRecord) throws -> (pending: PendingInput?, lastText: String, pendingCount: Int) {
        let owner = row.machineFingerprint
        let id = row.conversationID
        var descriptor = FetchDescriptor<FrameRecord>(
            predicate: #Predicate { $0.machineFingerprint == owner && $0.conversationID == id },
            sortBy: [SortDescriptor(\.seq, order: .reverse)]
        )
        descriptor.fetchLimit = Self.previewWindow
        let wantsPending = row.waitingForInput
        var pending: PendingInput?
        var lastText: String?
        var resolved = Set<String>()
        // 未落定的请求标识，按各自的 requestID 去重：数的是「有几件事等着」，不是「有几帧提到过它」。
        var pendingIDs = Set<String>()
        for frame in try modelContext.fetch(descriptor) {
            // 不等你处理时，找到最后一句话就可以收手；等你处理时必须看完整段窗口才数得全未处理的请求。
            if lastText != nil, !wantsPending { break }
            guard let notification = try? Agentre_Wire_RpcNotification(serializedBytes: frame.payload),
                  let event = notification.runtimeEventOfAnyTurn
            else { continue }
            switch event.event {
            case .textDelta(let delta) where lastText == nil && !delta.text.isEmpty:
                lastText = delta.text
            case .userMessage(let message) where lastText == nil && !message.text.isEmpty:
                lastText = message.text
            case .toolPermissionResolved(let resolution):
                resolved.insert(resolution.requestID)
            case .userAskResolved(let resolution):
                resolved.insert(resolution.requestID)
            case .toolPermissionRequest(let request) where wantsPending && !resolved.contains(request.requestID):
                if pendingIDs.insert(request.requestID).inserted, pending == nil {
                    pending = .permission(tool: request.toolName, detail: permissionDetail(request.input))
                }
            case .userAskRequest(let request) where wantsPending && !resolved.contains(request.requestID):
                if pendingIDs.insert(request.requestID).inserted, pending == nil {
                    let question = request.questions.first.map { $0.question.isEmpty ? $0.header : $0.question } ?? ""
                    pending = .question(question)
                }
            default:
                continue
            }
        }
        return (pending, lastText ?? "", pendingIDs.count)
    }

    /// 应用一条会话的一批帧。
    ///
    /// 逐帧先跟随、后落库，与 mirror_svc 的 Apply 同一次序：实时帧里号不大于游标的是重复
    /// 投递，它带的事实全部应用过了，连跟随都不再跑（重放一条早已落定的请求会把它算回「还等着」）。
    /// 落库只收带号的帧：库里已有的号与同批里重复的号都跳过，先到的为准。
    private func apply(_ frames: [IncomingFrame], to row: ConversationRecord) throws {
        let owner = row.machineFingerprint
        let id = row.conversationID
        let seqs = frames.compactMap(\.seq).filter { $0 > 0 }
        let stored = try modelContext.fetch(FetchDescriptor<FrameRecord>(
            predicate: #Predicate { $0.machineFingerprint == owner && $0.conversationID == id && seqs.contains($0.seq) }
        ))
        var seen = Set(stored.map(\.seq))
        for frame in frames {
            let seq = frame.seq ?? 0
            if frame.isLive, seq <= 0 || seq > row.latestSeq {
                follow(frame.payload, row: row)
            }
            guard seq > 0, seen.insert(seq).inserted else { continue }
            var payload = frame.payload
            payload.stamp(seq: seq)
            modelContext.insert(FrameRecord(
                machineFingerprint: owner, conversationID: id, seq: seq,
                createtime: frame.createtime ?? now(), payload: try payload.serializedData()
            ))
            row.latestSeq = max(row.latestSeq, seq)
        }
    }

    /// 让摘要跟着这一帧走（mirror_svc 的 followTurn + followWaiter）。只动生命周期、
    /// 最后活动与「等你处理」三格：标题之类仍只由清单说了算，帧里没有它们的答案。
    private func follow(_ notification: Agentre_Wire_RpcNotification, row: ConversationRecord) {
        let key = row.key
        if let lifecycle = notification.turnBoundaryLifecycle {
            row.lifecycleState = lifecycle
            // 边界帧上没有对端时刻，取本机钟；只前移不倒退——两台机器的钟不必一致。
            let at = now()
            if at > row.lastMessageAt { row.lastMessageAt = at }
            // 待决是按轮的：一轮结束，那一轮的待决就没人能回答了。终态帧因此是等待的兜底出口。
            if lifecycle != SavedConversation.Lifecycle.running {
                waiters[key] = []
                row.waitingForInput = false
            }
        }
        if let signal = notification.waiterSignal {
            // 按请求标识记集合而不是翻布尔：两次待决交错时，落定一次不能抹掉还在等的那一次。
            // 落定帧也建集合——它清掉的可能正是快照带来的那一次等待。
            var pending = waiters[key] ?? []
            switch signal {
            case .opened(let requestID): pending.insert(requestID)
            case .closed(let requestID): pending.remove(requestID)
            }
            waiters[key] = pending
            row.waitingForInput = !pending.isEmpty
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

/// 待批准的工具调用要跑的命令，或它要动的文件；两者都不在输入里时为 nil。
private func permissionDetail(_ input: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
    for field in ["command", "file_path"] {
        if let value = object[field] as? String, !value.isEmpty { return value }
    }
    return nil
}

private extension ConversationRecord {
    var key: ConversationKey {
        ConversationKey(machineFingerprint: machineFingerprint, conversationID: conversationID)
    }

    var snapshot: SavedConversation {
        SavedConversation(
            key: key,
            carrierFingerprint: viaFingerprint,
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
            readMarker: readMarker,
            providerKey: providerKey,
            modelKey: modelKey,
            reasoningEffort: reasoningEffort
        )
    }
}
