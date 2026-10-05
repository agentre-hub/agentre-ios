import AgentreDomain
@testable import AgentreUI
import Testing

@MainActor
@Suite("机器标签：名册")
struct MachinesModelTests {
    actor FakeRoster: MachineRoster {
        var result: Result<[Machine], any Error>
        init(_ result: Result<[Machine], any Error>) { self.result = result }
        func set(_ result: Result<[Machine], any Error>) { self.result = result }
        func machines() throws -> [Machine] { try result.get() }
    }

    @Test("名册与在线态取自 REST；在线的在前，同档按名字")
    func loadsRoster() async throws {
        let roster = FakeRoster(.success([
            Machine(id: 1, fingerprint: "a", name: "zeta", online: false),
            Machine(id: 2, fingerprint: "b", name: "beta", online: true),
            Machine(id: 3, fingerprint: "c", name: "alpha", online: false),
        ]))
        let model = MachinesModel(roster: roster, sessions: FakeSessionSource([]))
        await model.load()
        #expect(model.machines.map(\.name) == ["beta", "alpha", "zeta"])
        #expect(!model.loadFailed)
    }

    @Test("两次载入之间机器上线又下线：每次重新载入都按名册此刻的在线态重排，「没有可用的机器」随之出现或消失")
    func reloadFollowsPresence() async throws {
        let roster = FakeRoster(.success([Machine(id: 1, fingerprint: "a", name: "box", online: false)]))
        let model = MachinesModel(roster: roster, sessions: FakeSessionSource([]))
        await model.load()
        #expect(model.unavailable == .offline)
        await roster.set(.success([Machine(id: 1, fingerprint: "a", name: "box", online: true)]))
        await model.load()
        #expect(model.machines.map(\.online) == [true])
        #expect(model.unavailable == nil)
        await roster.set(.success([Machine(id: 1, fingerprint: "a", name: "box", online: false)]))
        await model.load()
        #expect(model.unavailable == .offline)
    }

    @Test("刷新失败时保留已有的名册；从没取到过才算取失败")
    func keepsRosterOnFailure() async throws {
        let roster = FakeRoster(.failure(CancellationError()))
        let model = MachinesModel(roster: roster, sessions: FakeSessionSource([]))
        await model.load()
        #expect(model.loadFailed)
        await roster.set(.success([Machine(id: 1, fingerprint: "a", name: "mac", online: true)]))
        await model.load()
        #expect(!model.loadFailed)
        await roster.set(.failure(CancellationError()))
        await model.load()
        #expect(model.machines.map(\.name) == ["mac"])
        #expect(!model.loadFailed)
    }

    @Test("在线机器各问一次现算的会话计数；离线的没有这一项，问不到的也没有（不当成零）")
    func loadsCountsForOnlineMachinesOnly() async throws {
        let roster = FakeRoster(.success([
            Machine(id: 1, fingerprint: "online-ok", name: "a", online: true),
            Machine(id: 2, fingerprint: "online-fails", name: "b", online: true),
            Machine(id: 3, fingerprint: "offline", name: "c", online: false),
        ]))
        let sessions = FakeSessionSource([])
        await sessions.setCounts(MachineSessionCounts(total: 5, running: 1, waiting: 2))
        await sessions.setFailing(machines: ["online-fails"])
        let model = MachinesModel(roster: roster, sessions: sessions)
        await model.load()
        #expect(model.counts["online-ok"] == MachineSessionCounts(total: 5, running: 1, waiting: 2))
        #expect(model.counts["online-fails"] == nil, "这一台问不到：没有这一项，不是零，也不连累别的机器")
        #expect(model.counts["offline"] == nil)
        await sessions.setFailing(machines: [])

        await sessions.setFailing(true)
        await model.load()
        #expect(model.counts["online-ok"] == nil, "问不到：没有这一项，不是零")
    }

    @Test("先发的那次载入晚到：不盖掉后发那次已经落下的名册与计数（下拉刷新与进屏载入叠在一起）")
    func staleLoadDoesNotOverwrite() async throws {
        let roster = FakeRoster(.success([Machine(id: 1, fingerprint: "box", name: "box", online: true)]))
        let sessions = FakeSessionSource([])
        await sessions.setCounts(MachineSessionCounts(total: 1, running: 0, waiting: 0), for: "box")
        await sessions.holdNextCountRequest()
        let model = MachinesModel(roster: roster, sessions: sessions)
        let first = Task { await model.load() }
        try await eventually("first load's count in flight") { await sessions.isHoldingCounts }

        await sessions.setCounts(MachineSessionCounts(total: 7, running: 2, waiting: 1), for: "box")
        await model.load()
        #expect(model.counts["box"] == MachineSessionCounts(total: 7, running: 2, waiting: 1))

        await sessions.releaseCounts()
        await first.value
        #expect(model.counts["box"] == MachineSessionCounts(total: 7, running: 2, waiting: 1), "先发的那次晚到，把计数退回了旧值")
    }

    @Test("载入随屏上的任务取消（点进一台机器的详情、名册页退场）：问到一半的计数不落下，已有的计数照旧")
    func cancelledLoadKeepsCounts() async throws {
        let roster = FakeRoster(.success([Machine(id: 1, fingerprint: "box", name: "box", online: true)]))
        let sessions = FakeSessionSource([])
        await sessions.setCounts(MachineSessionCounts(total: 7, running: 2, waiting: 1), for: "box")
        let model = MachinesModel(roster: roster, sessions: sessions)
        await model.load()
        #expect(model.counts["box"] == MachineSessionCounts(total: 7, running: 2, waiting: 1))

        await sessions.holdNextCountRequest()
        await sessions.setCancelling(true)
        let load = Task { await model.load() }
        try await eventually("count in flight") { await sessions.isHoldingCounts }
        load.cancel()
        await sessions.releaseCounts()
        await load.value
        #expect(model.counts["box"] == MachineSessionCounts(total: 7, running: 2, waiting: 1), "取消的那次把计数清掉了")
    }
}
