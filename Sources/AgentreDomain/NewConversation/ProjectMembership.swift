import Foundation

/// 继承自某一个祖先项目的那一组成员。
public struct InheritedMembers: Sendable, Equatable {
    public var ancestor: WorkspaceProject
    public var agents: [WorkspaceAgent]

    public init(ancestor: WorkspaceProject, agents: [WorkspaceAgent]) {
        self.ancestor = ancestor
        self.agents = agents
    }
}

/// 「这个项目里有哪些 Agent」：直接成员与继承自祖先项目的成员（控制台 projectMembers.ts 的移植）。
public struct ProjectMembership: Sendable, Equatable {
    public var direct: [WorkspaceAgent]
    /// 按祖先由近到远各一组；那一级没有新成员就不成组。
    public var inherited: [InheritedMembers]

    public init(direct: [WorkspaceAgent], inherited: [InheritedMembers]) {
        self.direct = direct
        self.inherited = inherited
    }

    /// 两组互斥：既是直接成员又是祖先成员时只算直接，同一个 Agent 在同一屏只出现一次。
    /// 继承按祖先由近及远收集，每个祖先一组（组名要写出祖先是谁，树里找不到的祖先说不出名字，不成组）；
    /// 树里成环时只走到环闭合处为止——列不全，而不是卡死。
    public init(of projectSyncID: String, projects: [WorkspaceProject], agents: [WorkspaceAgent]) {
        let byID = Dictionary(projects.map { ($0.syncID, $0) }, uniquingKeysWith: { first, _ in first })
        guard let project = byID[projectSyncID] else {
            self.init(direct: [], inherited: [])
            return
        }
        var ancestors: [WorkspaceProject] = []
        var seen: Set<String> = [projectSyncID]
        var cursor = project.parentSyncID
        while let id = cursor, !seen.contains(id), let ancestor = byID[id] {
            seen.insert(id)
            ancestors.append(ancestor)
            cursor = ancestor.parentSyncID
        }

        let direct = agents.filter { $0.projectSyncIDs.contains(projectSyncID) }
        var taken = Set(direct.map(\.syncID))
        var inherited: [InheritedMembers] = []
        for ancestor in ancestors {
            let members = agents.filter { !taken.contains($0.syncID) && $0.projectSyncIDs.contains(ancestor.syncID) }
            guard !members.isEmpty else { continue }
            taken.formUnion(members.map(\.syncID))
            inherited.append(InheritedMembers(ancestor: ancestor, agents: members))
        }
        self.init(direct: direct, inherited: inherited)
    }
}

/// 项目树摊平成一列（先根后子），带层级深度。
public struct WorkspaceProjectRow: Sendable, Equatable, Identifiable {
    public var project: WorkspaceProject
    public var depth: Int
    /// 从根到自己的一串项目名（胶囊写成「父 › 子」）。
    public var trail: [String]
    public var id: String { project.syncID }

    public init(project: WorkspaceProject, depth: Int, trail: [String]? = nil) {
        self.project = project
        self.depth = depth
        self.trail = trail ?? [project.name]
    }

    /// 同级按 sort_order，相同时保持服务端给的次序。父节点不在树里的当根；成环而够不到根的节点
    /// 在最后按根补上，一个都不丢。
    public static func flatten(_ projects: [WorkspaceProject]) -> [WorkspaceProjectRow] {
        let ids = Set(projects.map(\.syncID))
        let ordered = projects.enumerated()
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
            .map(\.element)
        let children = Dictionary(grouping: ordered) { project in
            project.parentSyncID.flatMap { ids.contains($0) ? $0 : nil } ?? ""
        }
        var rows: [WorkspaceProjectRow] = []
        var visited: Set<String> = []
        func visit(_ project: WorkspaceProject, depth: Int, above: [String]) {
            guard visited.insert(project.syncID).inserted else { return }
            let trail = above + [project.name]
            rows.append(WorkspaceProjectRow(project: project, depth: depth, trail: trail))
            for child in children[project.syncID] ?? [] { visit(child, depth: depth + 1, above: trail) }
        }
        for root in children[""] ?? [] { visit(root, depth: 0, above: []) }
        for project in ordered where !visited.contains(project.syncID) { visit(project, depth: 0, above: []) }
        return rows
    }
}
