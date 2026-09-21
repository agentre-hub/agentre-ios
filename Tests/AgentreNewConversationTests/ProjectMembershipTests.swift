import AgentreDomain
import Testing

/// 「这个项目里有哪些 Agent」——与控制台 projectMembers.ts 及其用例逐条对齐。
@Suite("项目成员继承")
struct ProjectMembershipTests {
    let agents = [
        agent("a-root", projects: ["root"]),
        agent("a-fe", projects: ["fe"]),
        agent("a-deep", projects: ["deep"]),
        agent("a-other", projects: ["other"]),
        agent("a-none"),
        agent("a-both", projects: ["root", "fe"]),
    ]

    func members(_ project: String, _ projects: [WorkspaceProject] = projectTree, _ agents: [WorkspaceAgent]? = nil) -> (direct: [String], inherited: [String]) {
        let membership = ProjectMembership(of: project, projects: projects, agents: agents ?? self.agents)
        return (membership.direct.map(\.syncID), membership.inherited.map(\.syncID))
    }

    @Test("直接成员 = 把这个项目写在自己名下的那些")
    func directMembers() {
        #expect(members("fe").direct == ["a-fe", "a-both"])
    }

    @Test("继承 = 祖先项目的直接成员，逐级往上走、由近及远")
    func inheritsUpTheChain() {
        #expect(members("deep").inherited == ["a-fe", "a-both", "a-root"])
    }

    @Test("同时是直接成员与祖先成员时只算直接，不在两组里各出现一次")
    func directWinsOverInherited() {
        let (direct, inherited) = members("fe")
        #expect(direct.contains("a-both"))
        #expect(!inherited.contains("a-both"))
    }

    @Test("根项目没有可继承的东西")
    func rootInheritsNothing() {
        let (direct, inherited) = members("root")
        #expect(direct == ["a-root", "a-both"])
        #expect(inherited.isEmpty)
    }

    @Test("不属于任何项目的 Agent 哪个项目里都不出现")
    func unaffiliatedNowhere() {
        for id in ["root", "fe", "deep", "other"] {
            let (direct, inherited) = members(id)
            #expect(!(direct + inherited).contains("a-none"))
        }
    }

    @Test("兄弟项目的成员不串味")
    func siblingsDoNotLeak() {
        let (direct, inherited) = members("other")
        #expect(direct == ["a-other"])
        #expect(inherited.isEmpty)
    }

    @Test("父子成环时不死循环，列不全而不是卡死")
    func cycleTerminates() {
        let cyclic = [
            WorkspaceProject(syncID: "x", name: "x", parentSyncID: "y"),
            WorkspaceProject(syncID: "y", name: "y", parentSyncID: "x"),
        ]
        #expect(members("x", cyclic, [agent("a-y", projects: ["y"])]).inherited == ["a-y"])
    }

    @Test("项目不存在时两组都空，而不是抛")
    func unknownProject() {
        let (direct, inherited) = members("gone")
        #expect(direct.isEmpty)
        #expect(inherited.isEmpty)
    }

    @Test("项目树摊平：先根后子、同级按 sort_order；成环的节点不丢也不卡死")
    func flattensTree() {
        let projects = [
            WorkspaceProject(syncID: "b", name: "b", sortOrder: 2),
            WorkspaceProject(syncID: "a", name: "a", sortOrder: 1),
            WorkspaceProject(syncID: "a2", name: "a2", parentSyncID: "a", sortOrder: 1),
            WorkspaceProject(syncID: "a1", name: "a1", parentSyncID: "a", sortOrder: 0),
            WorkspaceProject(syncID: "orphan", name: "orphan", parentSyncID: "gone", sortOrder: 3),
            WorkspaceProject(syncID: "x", name: "x", parentSyncID: "y", sortOrder: 4),
            WorkspaceProject(syncID: "y", name: "y", parentSyncID: "x", sortOrder: 5),
        ]
        let rows = WorkspaceProjectRow.flatten(projects)
        #expect(rows.map(\.project.syncID) == ["a", "a1", "a2", "b", "orphan", "x", "y"])
        #expect(rows.map(\.depth) == [0, 1, 1, 0, 0, 0, 1])
    }
}
