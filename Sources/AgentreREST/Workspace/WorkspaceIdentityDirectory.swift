import AgentreDomain
import Foundation

/// `IdentityDirectory` 的实现：项目树取工作区项目树（`/v1/workspace/projects`），机器名取机器
/// 名册（`/v1/devices`）。两份材料各自取一次就缓存；取不到时保留已有的一份，与
/// `MachinesModel.load` 同一策略——但项目树在**第一次**取到之前如实报告「还没取到过」
/// （`projects()` 为 `nil`），不能拿「空数组」去冒充它，那会把「离线冷启动」误判成
/// 「账号下没有项目」。
public actor WorkspaceIdentityDirectory: IdentityDirectory {
    private let workspace: any WorkspaceService
    private let roster: any MachineRoster
    private var loadedProjects: [WorkspaceProject]?
    private var loadedMachines: [Machine] = []
    private var observers: [AsyncStream<Void>.Continuation] = []

    public init(workspace: any WorkspaceService, roster: any MachineRoster) {
        self.workspace = workspace
        self.roster = roster
    }

    public func load() async {
        async let projectList = try? workspace.projects()
        async let machineList = try? roster.machines()
        let projects = await projectList
        let machines = await machineList
        if let projects { loadedProjects = projects }
        if let machines { loadedMachines = machines }
        // 取到了哪一份就告诉订阅者：已经画出来的空白字形、按项目名与机器名的搜索随之补上。
        guard projects != nil || machines != nil else { return }
        observers.removeAll { if case .terminated = $0.yield() { true } else { false } }
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers.append(continuation)
        return stream
    }

    public func projects() -> [WorkspaceProject]? { loadedProjects }

    public func machineName(fingerprint: String) -> String? {
        loadedMachines.first { $0.fingerprint == fingerprint }?.name
    }
}
