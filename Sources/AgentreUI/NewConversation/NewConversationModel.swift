import AgentreDomain
import Foundation
import Observation

/// 新建对话入口的状态：全部 Agent 与项目树取自服务端，「最近用过」取自本地库。
@MainActor
@Observable
public final class NewConversationModel {
    public private(set) var agents: [WorkspaceAgent] = []
    public private(set) var recent: [WorkspaceAgent] = []
    /// 项目树摊平成一列，带层级深度。
    public private(set) var projectRows: [WorkspaceProjectRow] = []
    public private(set) var loadFailed = false
    public var query = ""

    private let workspace: any WorkspaceService
    private let store: any ConversationStore

    public init(workspace: any WorkspaceService, store: any ConversationStore) {
        self.workspace = workspace
        self.store = store
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isSearching: Bool { !trimmedQuery.isEmpty }

    /// 搜索时只剩名字匹配的；不搜时是全部。
    public var visibleAgents: [WorkspaceAgent] {
        let needle = trimmedQuery
        guard !needle.isEmpty else { return agents }
        return agents.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    public var projects: [WorkspaceProject] { projectRows.map(\.project) }

    /// 取清单与项目树；取不到时保留已有的内容并记下失败。本地库读不出只是没有「最近用过」。
    public func load() async {
        do {
            async let agentList = workspace.agents()
            async let projectList = workspace.projects()
            let (loadedAgents, loadedProjects) = try await (agentList, projectList)
            agents = loadedAgents
            projectRows = WorkspaceProjectRow.flatten(loadedProjects)
            loadFailed = false
        } catch {
            loadFailed = true
            return
        }
        let conversations = (try? await store.conversations()) ?? []
        recent = RecentAgents.pick(from: conversations, agents: agents)
    }

    public func membership(of projectSyncID: String) -> ProjectMembership {
        ProjectMembership(of: projectSyncID, projects: projects, agents: agents)
    }
}
