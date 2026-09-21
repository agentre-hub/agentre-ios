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
        let model = MachinesModel(roster: roster)
        await model.load()
        #expect(model.machines.map(\.name) == ["beta", "alpha", "zeta"])
        #expect(!model.loadFailed)
    }

    @Test("刷新失败时保留已有的名册；从没取到过才算取失败")
    func keepsRosterOnFailure() async throws {
        let roster = FakeRoster(.failure(CancellationError()))
        let model = MachinesModel(roster: roster)
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
}
