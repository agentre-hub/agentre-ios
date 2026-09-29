import AgentreDomain
import AgentreREST
import Testing

/// 会话头像字形与副标题要问的两件事：项目树取到了没有、承载机器叫什么名字
/// （按 `project_sync_id` 与承载机器指纹查，任务 42 留给后续屏幕的目录）。
@Suite("身份目录：项目树 + 机器名")
struct WorkspaceIdentityDirectoryTests {
    actor FakeRoster: MachineRoster {
        var result: Result<[Machine], any Error>
        init(_ result: Result<[Machine], any Error>) { self.result = result }
        func set(_ result: Result<[Machine], any Error>) { self.result = result }
        func machines() throws -> [Machine] { try result.get() }
    }

    @Test("一次都没取到过时项目树为 nil；取到后就是那一份")
    func projectsStartAsNilUntilLoaded() async {
        let workspace = FakeWorkspace(projects: [WorkspaceProject(syncID: "p1", name: "server")])
        let directory = WorkspaceIdentityDirectory(workspace: workspace, roster: FakeRoster(.success([])))
        let before = await directory.projects()
        #expect(before == nil)
        await directory.load()
        let after = await directory.projects()
        #expect(after == [WorkspaceProject(syncID: "p1", name: "server")])
    }

    @Test("取不到时保留上一次取到的项目树，不退回「没取到过」")
    func keepsProjectsOnFailure() async {
        let workspace = FakeWorkspace(projects: [WorkspaceProject(syncID: "p1", name: "server")])
        let directory = WorkspaceIdentityDirectory(workspace: workspace, roster: FakeRoster(.success([])))
        await directory.load()
        await workspace.configure(failProjects: true)
        await directory.load()
        let projects = await directory.projects()
        #expect(projects == [WorkspaceProject(syncID: "p1", name: "server")])
    }

    @Test("机器名取自名册，查不到即 nil")
    func machineNameFromRoster() async {
        let roster = FakeRoster(.success([Machine(id: 1, fingerprint: "fp-a", name: "mac-studio", online: true)]))
        let directory = WorkspaceIdentityDirectory(workspace: FakeWorkspace(), roster: roster)
        #expect(await directory.machineName(fingerprint: "fp-a") == nil, "取之前不该凭空给出名字")
        await directory.load()
        #expect(await directory.machineName(fingerprint: "fp-a") == "mac-studio")
        #expect(await directory.machineName(fingerprint: "fp-missing") == nil)
    }
}
