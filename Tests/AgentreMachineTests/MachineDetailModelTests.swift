import AgentreDomain
@testable import AgentreUI
import Testing

/// 机器详情的发现：现问机器要清单与计数，按游标翻页，改搜索词回到起点，行上分得清已保存与未保存。
@MainActor
@Suite("机器详情：发现")
struct MachineDetailModelTests {
    func sessions(_ count: Int) -> [MachineSession] {
        (0..<count).map { session("c\($0)", title: "task \($0)", at: Int64(10_000 - $0)) }
    }

    func model(
        _ source: FakeSessionSource, store: FakeSavingStore = FakeSavingStore(), machine: Machine = onlineMachine(), pageSize: Int = 2
    ) -> MachineDetailModel {
        MachineDetailModel(machine: machine, sessions: source, store: store, transfer: FakeTransfer(), pageSize: pageSize)
    }

    @Test("打开即问机器要第一页与三个计数；翻到底不重不漏，最后一页之后不再要")
    func pagesWithoutGapsOrRepeats() async throws {
        let source = FakeSessionSource(sessions(5))
        await source.setCounts(MachineSessionCounts(total: 5, running: 2, waiting: 1))
        let detail = model(source)
        await detail.load()
        #expect(detail.counts == MachineSessionCounts(total: 5, running: 2, waiting: 1))
        #expect(detail.rows.map(\.session.conversationID) == ["c0", "c1"])
        #expect(detail.hasMore)
        await detail.loadMore()
        await detail.loadMore()
        #expect(detail.rows.map(\.session.conversationID) == ["c0", "c1", "c2", "c3", "c4"])
        #expect(!detail.hasMore)
        await detail.loadMore()
        let requests = await source.requests
        #expect(requests.map(\.cursor) == ["", "2", "4"])
        #expect(requests.allSatisfy { $0.machine == machineFingerprint && $0.limit == 2 && $0.keyword.isEmpty })
    }

    @Test("两页之间机器上新增了会话：清单往后挤，已列过的那一条不再出现第二次")
    func noRepeatsWhenTheListShifts() async throws {
        let source = FakeSessionSource(sessions(4))
        let detail = model(source)
        await detail.load()
        await source.setSessions([session("new", title: "new")] + sessions(4))
        await detail.loadMore()
        await detail.loadMore()
        #expect(detail.rows.map(\.session.conversationID) == ["c0", "c1", "c2", "c3"])
    }

    @Test("改搜索词：游标回到起点，关键词原样交给机器，列表换成新的集合")
    func newKeywordRestartsAtTheBeginning() async throws {
        let source = FakeSessionSource([
            session("a", title: "Fix build"), session("b", title: "docs"), session("c", title: "fix tests"), session("d", title: "fix lint"),
        ])
        let detail = model(source)
        await detail.load()
        await detail.loadMore()
        await detail.search("fix")
        #expect(detail.keyword == "fix")
        #expect(detail.rows.map(\.session.conversationID) == ["a", "c"])
        await detail.loadMore()
        #expect(detail.rows.map(\.session.conversationID) == ["a", "c", "d"])
        let requests = await source.requests
        #expect(requests.map(\.cursor) == ["", "2", "", "2"])
        #expect(requests.map(\.keyword) == ["", "", "fix", "fix"])
    }

    @Test("旧关键词的答复晚到：丢弃，不混进新集合")
    func staleAnswerIsDropped() async throws {
        let source = FakeSessionSource([session("a", title: "alpha"), session("b", title: "beta")])
        let detail = model(source)
        await detail.load()
        await source.hold("al")
        let slow = Task { await detail.search("al") }
        try await eventually("held") { await source.isHolding("al") }
        await detail.search("be")
        await source.release("al")
        await slow.value
        #expect(detail.keyword == "be")
        #expect(detail.rows.map(\.session.conversationID) == ["b"])
    }

    @Test("每行的已保存／未保存与本地库一致；经发起端回显的会话按发起端认")
    func savedStateMatchesTheStore() async throws {
        let source = FakeSessionSource([session("a"), session("b"), session("c", peer: "fp-laptop")])
        let store = FakeSavingStore(saved: [key("a"), key("c", machine: "fp-laptop"), key("b", machine: "fp-other")])
        let detail = model(source, store: store, pageSize: 10)
        await detail.load()
        #expect(detail.rows.map(\.isSaved) == [true, false, true])
        #expect(detail.rows[2].key == key("c", machine: "fp-laptop"))
    }

    @Test("本地库变了（在消息列表里删掉一条）：这一行回到未保存")
    func followsTheStore() async throws {
        let source = FakeSessionSource([session("a")])
        let store = FakeSavingStore(saved: [key("a")])
        let detail = model(source, store: store)
        await detail.load()
        #expect(detail.rows.first?.isSaved == true)
        let following = Task { await detail.follow() }
        defer { following.cancel() }
        try await eventually("follow started") { await store.observerCount > 0 }
        await store.delete(key("a"))
        try await eventually("row unsaved") { detail.rows.first?.isSaved == false }
    }

    @Test("机器离线：不问机器，没有会话、没有计数（不是零）")
    func offlineAsksNothing() async throws {
        let source = FakeSessionSource(sessions(3))
        await source.setCounts(MachineSessionCounts(total: 3, running: 0, waiting: 0))
        let detail = model(source, machine: offlineMachine())
        await detail.load()
        await detail.loadMore()
        await detail.search("task")
        #expect(detail.rows.isEmpty)
        #expect(detail.counts == nil)
        #expect(await source.requests.isEmpty)
        #expect(await source.countRequests == 0)
    }

    @Test("名册说在线、中继上没问到：没有会话、没有计数，标记为没连上")
    func relayFailureShowsNothing() async throws {
        let source = FakeSessionSource(sessions(3))
        await source.setFailing(true)
        let detail = model(source)
        await detail.load()
        #expect(detail.unreachable)
        #expect(detail.rows.isEmpty)
        #expect(detail.counts == nil)
        await source.setFailing(false)
        await detail.load()
        #expect(!detail.unreachable)
        #expect(detail.rows.map(\.session.conversationID) == ["c0", "c1"])
    }

    @Test("「再加载 N 条」的 N：机器报的总数减去已列出的条数，以一页为上限；列全了没有")
    func reloadCountCapsAtOnePage() throws {
        #expect(MachineDetailModel.reloadCount(total: 17, listed: 4, pageSize: 10) == 10)
        #expect(MachineDetailModel.reloadCount(total: 8, listed: 4, pageSize: 10) == 4)
        #expect(MachineDetailModel.reloadCount(total: 4, listed: 4, pageSize: 10) == nil)
        #expect(MachineDetailModel.reloadCount(total: 0, listed: 0, pageSize: 10) == nil)
    }

    @Test("接上 sessionList 的 total：列表底部按钮的 N 随翻页与改搜索词一起更新，机器离线时没有这个按钮")
    func reloadCountTracksTheServerTotal() async throws {
        let source = FakeSessionSource(sessions(5))
        let detail = model(source, pageSize: 2)
        await detail.load()
        #expect(detail.reloadCount == 2, "还剩 5-2=3 条，以一页（2）为上限")
        await detail.loadMore()
        #expect(detail.reloadCount == 1)
        await detail.loadMore()
        #expect(detail.reloadCount == nil, "列全了")

        let offline = model(FakeSessionSource(sessions(5)), machine: offlineMachine(), pageSize: 2)
        await offline.load()
        #expect(offline.reloadCount == nil, "机器离线：不问，也没有这个按钮")
    }

    @Test("重新载入被取消（点进一行、屏上的任务随之取消）：不是没连上，已列出的行照旧")
    func cancelledReloadIsNotUnreachable() async throws {
        let source = FakeSessionSource(sessions(3))
        let detail = model(source)
        await detail.load()
        #expect(detail.rows.map(\.session.conversationID) == ["c0", "c1"])
        await source.setCancelling(true)
        await detail.load()
        #expect(!detail.unreachable)
        #expect(detail.rows.map(\.session.conversationID) == ["c0", "c1"])
    }
}
