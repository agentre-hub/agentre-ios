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
        let model = MachinesModel(roster: roster, sessions: sessions)
        await model.load()
        #expect(model.counts["online-ok"] == MachineSessionCounts(total: 5, running: 1, waiting: 2))
        #expect(model.counts["offline"] == nil)

        await sessions.setFailing(true)
        await model.load()
        #expect(model.counts["online-ok"] == nil, "问不到：没有这一项，不是零")
    }
}
