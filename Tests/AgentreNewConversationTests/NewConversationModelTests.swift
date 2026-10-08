import AgentreDomain
@testable import AgentreUI
import Testing

/// 新建对话入口：搜索、最近用过、全部 Agent，以及「从项目里挑」。
@MainActor
@Suite("新建对话入口视图模型")
struct NewConversationModelTests {
    let agents = [agent("Coder", projects: ["fe"]), agent("reviewer", projects: ["root"]), agent("writer")]

    @Test("载入即给出全部 Agent、项目树与本地库里最近用过的")
    func loads() async throws {
        let store = FakeConversationStore([saved("1", agent: "writer", last: 200), saved("2", agent: "Coder", last: 100)])
        let model = NewConversationModel(workspace: FakeWorkspace(agents: agents), store: store)
        await model.load()
        #expect(model.agents.map(\.syncID) == ["Coder", "reviewer", "writer"])
        #expect(model.recent.map(\.syncID) == ["writer", "Coder"])
        #expect(model.projectRows.map(\.project.syncID) == ["root", "fe", "deep", "other"])
        #expect(model.projectRows.map(\.depth) == [0, 1, 2, 0])
        #expect(!model.loadFailed)
    }

    @Test("搜索按名字不分大小写过滤；清空后回到全部")
    func search() async throws {
        let model = NewConversationModel(workspace: FakeWorkspace(agents: agents), store: FakeConversationStore())
        await model.load()
        model.query = "  cOd "
        #expect(model.visibleAgents.map(\.syncID) == ["Coder"])
        #expect(model.isSearching)
        model.query = ""
        #expect(model.visibleAgents.map(\.syncID) == ["Coder", "reviewer", "writer"])
        #expect(!model.isSearching)
    }

    @Test("取不到清单时如实记下，重试成功后清掉")
    func loadFailure() async throws {
        let workspace = FakeWorkspace(agents: agents)
        await workspace.configure(failAgents: true)
        let model = NewConversationModel(workspace: workspace, store: FakeConversationStore())
        await model.load()
        #expect(model.loadFailed)
        await workspace.configure(failAgents: false)
        await model.load()
        #expect(!model.loadFailed)
        #expect(model.agents.count == 3)
    }

    @Test("在项目下选 Agent：直接成员与继承成员分两组")
    func membersOfProject() async throws {
        let model = NewConversationModel(workspace: FakeWorkspace(agents: agents), store: FakeConversationStore())
        await model.load()
        let membership = model.membership(of: "deep")
        #expect(membership.direct.isEmpty)
        #expect(membership.inherited.map(\.ancestor.name) == ["frontend", "agentre-server"])
        #expect(membership.inherited.map { $0.agents.map(\.syncID) } == [["Coder"], ["reviewer"]])
    }

    @Test("「从项目里挑」卡片写项目个数")
    func projectCount() async throws {
        let model = NewConversationModel(workspace: FakeWorkspace(agents: agents), store: FakeConversationStore())
        #expect(model.projectCount == 0)
        await model.load()
        #expect(model.projectCount == 4)
    }

    @Test("项目下每个 Agent 的落点取这个项目的派发结果（带项目问派发计划），不取清单里与项目无关的 current")
    func landingsComeFromTheProjectPlan() async throws {
        let workspace = FakeWorkspace(agents: agents, planner: { query in
            if query.agentSyncID == "reviewer" {
                return DispatchPlan(agentSyncID: "reviewer", tiers: [
                    DispatchTier(rank: 1, backendSyncID: "b1", deviceName: "laptop", backendType: "claudecode", availability: .projectPathMissing),
                ], chosen: nil)
            }
            return plan(for: query)
        })
        let model = NewConversationModel(workspace: workspace, store: FakeConversationStore())
        await model.load()
        #expect(model.landing(of: "Coder", in: "deep") == nil)
        await model.loadLandings(in: "deep")
        #expect(Set(await workspace.planQueries) == [
            DispatchPlanQuery(agentSyncID: "Coder", projectSyncID: "deep"), DispatchPlanQuery(agentSyncID: "reviewer", projectSyncID: "deep"),
        ])
        #expect(model.landing(of: "Coder", in: "deep") == .resolved(.landsOn(device: "mini", cwd: "/srv/deep")))
        #expect(model.landing(of: "reviewer", in: "deep") == .resolved(.unavailable(device: "laptop", reason: .projectPathMissing)))
        #expect(model.landing(of: "Coder", in: "fe") == nil)
    }

    @Test("某个 Agent 的派发计划没问到：那一行记作没问到，其余照常")
    func landingFailure() async throws {
        let workspace = FakeWorkspace(agents: agents)
        await workspace.configure(failPlans: true)
        let model = NewConversationModel(workspace: workspace, store: FakeConversationStore())
        await model.load()
        await model.loadLandings(in: "fe")
        #expect(model.landing(of: "Coder", in: "fe") == .failed)
    }

    @Test("再进「从项目里挑」重问落点：上次问到「离线」的那台此刻上线了，这一行跟着可用（不沿用整段登录期的旧答案）")
    func reenteringThePickerAsksAgain() async throws {
        let offline: @Sendable (DispatchPlanQuery) -> DispatchPlan = { query in
            DispatchPlan(agentSyncID: query.agentSyncID, tiers: [
                DispatchTier(rank: 1, backendSyncID: "b1", deviceName: "mini", backendType: "claudecode", availability: .offline),
            ], chosen: nil)
        }
        let workspace = FakeWorkspace(agents: agents, planner: offline)
        let model = NewConversationModel(workspace: workspace, store: FakeConversationStore())
        await model.load()
        await model.enterProjectPicker()
        #expect(model.selectedProjectID == "root")
        #expect(model.landing(of: "reviewer", in: "root") == .resolved(.unavailable(device: "mini", reason: .offline)))

        await workspace.set(planner: plan(for:))
        await model.load()
        await model.enterProjectPicker()
        #expect(model.landing(of: "reviewer", in: "root") == .resolved(.landsOn(device: "mini", cwd: "/srv/root")))
    }

    @Test("上次选中的项目已在别处删掉：再进「从项目里挑」落回第一个项目，而不是一片空白")
    func selectedProjectGoneFallsBackToFirst() async throws {
        let workspace = FakeWorkspace(agents: agents)
        let model = NewConversationModel(workspace: workspace, store: FakeConversationStore())
        await model.load()
        await model.enterProjectPicker()
        await model.selectProject("deep")
        await workspace.set(projects: projectTree.filter { $0.syncID != "deep" })
        await model.load()
        await model.enterProjectPicker()
        #expect(model.selectedProjectID == "root")
    }
}
