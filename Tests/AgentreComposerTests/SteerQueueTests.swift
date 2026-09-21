import AgentreDomain
import Testing

/// 排队插话的状态迁移，规则逐条对齐宿主 agentre-ui 的 composer/steer-queue.ts 及其用例；
/// 轮末去向对齐控制台的 useSteerQueue（还剩的挪进 dropped，不静默清掉）。
@Suite("排队插话")
struct SteerQueueTests {
    /// 攒一条已经拿到权威句柄的排队消息。
    func settled(_ id: String, _ text: String, cancellable: Bool = true) -> SteerQueue {
        var queue = SteerQueue()
        queue.enqueue(id: "local-\(id)", text: text)
        queue.adopt(localID: "local-\(id)", handle: ComposerSteerHandle(queuedID: id, cancellable: cancellable))
        return queue
    }

    @Test("刚提交的一条先以本地句柄挂着且不可撤销")
    func enqueuePending() {
        var queue = SteerQueue()
        queue.enqueue(id: "local-1", text: "等一下")
        #expect(queue.items == [QueuedSteer(id: "local-1", text: "等一下", cancellable: false, pending: true)])
    }

    @Test("应答带回权威句柄：句柄与可撤销随之落定")
    func adoptHandle() {
        #expect(settled("d-42", "等一下").items == [QueuedSteer(id: "d-42", text: "等一下", cancellable: true, pending: false)])
    }

    @Test("对端还没升级（应答没有句柄）：留在降级档，本地句柄、锁住")
    func adoptEmptyHandle() {
        var queue = SteerQueue()
        queue.enqueue(id: "local-1", text: "等一下")
        queue.adopt(localID: "local-1", handle: ComposerSteerHandle(queuedID: "", cancellable: true))
        #expect(queue.items == [QueuedSteer(id: "local-1", text: "等一下", cancellable: false, pending: true)])
    }

    @Test("消费事件先于应答到达：认领那个已被消费的句柄时这条不复活")
    func consumedBeforeAdopt() {
        var queue = SteerQueue()
        queue.enqueue(id: "local-1", text: "等一下")
        queue.consume([ComposerConsumedSteer(queuedID: "d-42", text: "等一下")])
        queue.adopt(localID: "local-1", handle: ComposerSteerHandle(queuedID: "d-42", cancellable: true))
        #expect(queue.items.isEmpty)
    }

    @Test("按句柄消费：对应那条消失；同一事件到两次什么都不再发生")
    func consumeByHandle() {
        var queue = settled("d-42", "等一下")
        queue.consume([ComposerConsumedSteer(queuedID: "d-42", text: "等一下")])
        #expect(queue.items.isEmpty)
        queue.consume([ComposerConsumedSteer(queuedID: "d-42", text: "等一下")])
        #expect(queue.items.isEmpty)
    }

    @Test("别的端排的消息被消费、句柄对不上：本地这条一动不动（落定的条目不按文本猜）")
    func foreignConsumeLeavesSettled() {
        var queue = settled("d-42", "等一下")
        queue.consume([ComposerConsumedSteer(queuedID: "other-7", text: "等一下")])
        #expect(queue.items.map(\.id) == ["d-42"])
    }

    @Test("降级档里两条同文本：只抵消最早那一条")
    func textFallbackOnlyEarliestPending() {
        var queue = SteerQueue()
        queue.enqueue(id: "local-1", text: "等一下")
        queue.enqueue(id: "local-2", text: "等一下")
        queue.consume([ComposerConsumedSteer(queuedID: "d-42", text: "等一下")])
        #expect(queue.items.map(\.id) == ["local-2"])
    }

    @Test("撤回成功：按句柄移除")
    func drop() {
        var queue = settled("d-42", "等一下")
        queue.drop(["d-42"])
        #expect(queue.items.isEmpty)
    }

    @Test("撤回被拒：留在原位、转成锁住")
    func refuseCancel() {
        var queue = settled("d-42", "等一下")
        queue.markNotCancellable("d-42")
        #expect(queue.items == [QueuedSteer(id: "d-42", text: "等一下", cancellable: false, pending: false)])
    }

    @Test("一轮结束：还剩的挪进 dropped 不静默清掉，已消费记录作废；已有一份暂存时不覆盖")
    func endTurnKeepsLeftovers() {
        var queue = settled("d-42", "等一下")
        queue.consume([ComposerConsumedSteer(queuedID: "x-1")])
        queue.endTurn()
        #expect(queue.items.isEmpty)
        #expect(queue.dropped.map(\.text) == ["等一下"])
        queue.enqueue(id: "local-9", text: "再说")
        queue.endTurn()
        #expect(queue.dropped.map(\.text) == ["等一下"])
        queue.clearDropped()
        #expect(queue.dropped.isEmpty)
        // 已消费记录随轮作废：上一轮的 x-1 不再挡住这一轮的认领。
        queue.enqueue(id: "local-3", text: "c")
        queue.adopt(localID: "local-3", handle: ComposerSteerHandle(queuedID: "x-1", cancellable: true))
        #expect(queue.items.map(\.id) == ["x-1"])
    }

    @Test("空队列轮末什么都不挪")
    func endTurnEmpty() {
        var queue = SteerQueue()
        queue.endTurn()
        #expect(queue.dropped.isEmpty && queue.items.isEmpty)
    }
}
