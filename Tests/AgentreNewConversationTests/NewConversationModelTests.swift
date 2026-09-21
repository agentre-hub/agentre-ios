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
        #expect(membership.inherited.map(\.syncID) == ["Coder", "reviewer"])
    }
}
