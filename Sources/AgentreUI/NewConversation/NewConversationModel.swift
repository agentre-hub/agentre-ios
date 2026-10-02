import AgentreDomain
import Foundation
import Observation

/// 「从项目里挑」一行的落点：带项目问到的派发结果，或没问到。还在问时没有这一项。
public enum ProjectLandingState: Equatable, Sendable {
    case resolved(ProjectLanding)
    case failed
}

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
    /// 「从项目里挑」里选中的项目；进那一屏时缺省为项目树的第一个。
    public private(set) var selectedProjectID: String?
    /// 项目 → Agent → 落点。
    private var landings: [String: [String: ProjectLandingState]] = [:]

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

    public var projectCount: Int { projectRows.count }

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

    /// 这个项目下这个 Agent 此刻落到哪；nil = 还在问。
    public func landing(of agentSyncID: String, in projectSyncID: String) -> ProjectLandingState? {
        landings[projectSyncID]?[agentSyncID]
    }

    /// 选中一个项目并问它的落点。
    public func selectProject(_ projectSyncID: String) async {
        selectedProjectID = projectSyncID
        await loadLandings(in: projectSyncID)
    }

    /// 项目下的每个 Agent 各带这个项目问一次派发计划：落点（机器与工作目录）只有它说得准——清单里的
    /// `current` 不看项目。问到过的不再问；没问到的下次选中时重问。
    public func loadLandings(in projectSyncID: String) async {
        let membership = membership(of: projectSyncID)
        let known = landings[projectSyncID] ?? [:]
        let pending = (membership.direct + membership.inherited.flatMap(\.agents)).map(\.syncID).filter {
            if case .resolved = known[$0] { return false }
            return true
        }
        guard !pending.isEmpty else { return }
        let workspace = workspace
        await withTaskGroup(of: (String, ProjectLandingState).self) { group in
            for agent in pending {
                group.addTask {
                    let query = DispatchPlanQuery(agentSyncID: agent, projectSyncID: projectSyncID)
                    guard let plan = try? await workspace.dispatchPlan(query) else { return (agent, .failed) }
                    return (agent, .resolved(plan.landing))
                }
            }
            for await (agent, state) in group {
                landings[projectSyncID, default: [:]][agent] = state
            }
        }
    }
}
