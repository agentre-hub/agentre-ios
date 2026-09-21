import Foundation

// 「这一轮进行中排着的那几条插话」的状态迁移，规则逐条移植自宿主
// agentre-ui/src/composer/steer-queue.ts；轮末去向（还剩的挪进 dropped，不静默清掉）
// 对齐控制台 agentre-server/frontend/src/components/session/useSteerQueue.ts。

/// 队列里的一条。`id` 是撤回时递给对端的句柄。
public struct QueuedSteer: Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    /// 这条链路上撤不撤得掉（对端自报）。降级档与未落定的一律为假。
    public var cancellable: Bool
    /// 还没拿到执行端认的句柄：撤不掉，消费时只能按文本抵消。
    public var pending: Bool

    public init(id: String, text: String, cancellable: Bool, pending: Bool) {
        self.id = id
        self.text = text
        self.cancellable = cancellable
        self.pending = pending
    }
}

/// 一条会话此刻排着的插话，与轮末没被取走、等用户处置的那一份。
public struct SteerQueue: Sendable, Equatable {
    public private(set) var items: [QueuedSteer] = []
    /// 轮末没被取走的那几条；空 = 没有。
    public private(set) var dropped: [QueuedSteer] = []
    /// 本轮已被消费、却没对上任何一条的权威句柄：消费事件可能先于发送应答到达。
    private var consumed: [String] = []

    /// 记住的已消费句柄条数上限。
    private static let consumedMemory = 64

    public init() {}

    /// 排进一条刚提交、还没拿到执行端句柄的插话（提交那一刻输入框已清空，这段字只存在于队列里）。
    public mutating func enqueue(id: String, text: String) {
        items.append(QueuedSteer(id: id, text: text, cancellable: false, pending: true))
    }

    /// 应答回来了：已被消费过的句柄不复活；应答没有句柄的留在降级档；否则落定。
    public mutating func adopt(localID: String, handle: ComposerSteerHandle) {
        guard let index = items.firstIndex(where: { $0.id == localID && $0.pending }) else { return }
        if !handle.queuedID.isEmpty, consumed.contains(handle.queuedID) {
            items.remove(at: index)
            return
        }
        guard !handle.queuedID.isEmpty else { return }
        items[index].id = handle.queuedID
        items[index].cancellable = handle.cancellable
        items[index].pending = false
    }

    /// 后端取走了这几条：按句柄消费；句柄对不上就按文本抵消降级档里最早那一条。
    /// 落定的条目一律只认句柄——别的端排的同文本消息被消费时不能把自己这条清掉。
    public mutating func consume(_ refs: [ComposerConsumedSteer]) {
        for ref in refs {
            if !ref.queuedID.isEmpty {
                if let index = items.firstIndex(where: { !$0.pending && $0.id == ref.queuedID }) {
                    items.remove(at: index)
                    continue
                }
                remember(ref.queuedID)
            }
            guard !ref.text.isEmpty else { continue }
            if let index = items.firstIndex(where: { $0.pending && $0.text == ref.text }) {
                items.remove(at: index)
            }
        }
    }

    /// 撤回成功、或这条根本没发出去：按句柄移除。
    public mutating func drop(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let drop = Set(ids)
        items.removeAll { drop.contains($0.id) }
    }

    /// 撤回被对端拒了：留在原位，转成撤不掉。
    public mutating func markNotCancellable(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].cancellable = false
    }

    /// 一轮结束：还剩的挪进 dropped 等用户处置；上一轮的还没处置时接在它后面，两轮的都不丢。
    /// 已消费记录随这一轮作废。
    public mutating func endTurn() {
        consumed = []
        guard !items.isEmpty else { return }
        dropped += items
        items = []
    }

    public mutating func clearDropped() {
        dropped = []
    }

    private mutating func remember(_ id: String) {
        guard !consumed.contains(id) else { return }
        consumed.append(id)
        if consumed.count > Self.consumedMemory { consumed.removeFirst(consumed.count - Self.consumedMemory) }
    }
}
