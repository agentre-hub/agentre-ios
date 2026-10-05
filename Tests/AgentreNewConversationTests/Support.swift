import AgentreDomain
import AgentreStore
@testable import AgentreUI
import AgentreWire
import Foundation
import Testing

// MARK: 样本

let projectTree: [WorkspaceProject] = [
    WorkspaceProject(syncID: "root", name: "agentre-server"),
    WorkspaceProject(syncID: "fe", name: "frontend", parentSyncID: "root"),
    WorkspaceProject(syncID: "deep", name: "components", parentSyncID: "fe"),
    WorkspaceProject(syncID: "other", name: "agentre"),
]

func agent(_ id: String, projects: [String] = [], targets: [ExecTarget]? = nil) -> WorkspaceAgent {
    let chain = targets ?? [ExecTarget(rank: 1, deviceName: "mac-\(id)", backendType: "claudecode", availability: .available, current: true)]
    return WorkspaceAgent(syncID: id, name: id, projectSyncIDs: projects, execTargets: chain, hasAvailableTarget: chain.contains { $0.availability.isAvailable })
}

let tiers: [DispatchTier] = [
    DispatchTier(rank: 1, backendSyncID: "b-off", deviceName: "studio", backendType: "claudecode", kind: "agentred", availability: .offline),
    DispatchTier(rank: 2, backendSyncID: "b-mini", deviceName: "mini", backendType: "codex", kind: "agentred", availability: .available),
    DispatchTier(rank: 3, backendSyncID: "b-unpaired", backendType: "claudecode", availability: .unpaired),
    DispatchTier(rank: 4, backendSyncID: "b-path", deviceName: "laptop", backendType: "claudecode", kind: "agentred", availability: .projectPathMissing),
    DispatchTier(rank: 5, backendSyncID: "b-box", deviceName: "box", backendType: "codex", kind: "agentred", availability: .available),
]

func choice(_ name: String, backend: String, cwd: String = "") -> DispatchChoice {
    DispatchChoice(deviceFingerprint: "fp-\(name)", deviceName: name, backendSyncID: backend, backendType: "codex", kind: "agentred", cwd: cwd)
}

/// 与服务端同一条规矩的派发计划：手动指定的那一档跑不了时不回落；自动取第一档可用的。
func plan(for query: DispatchPlanQuery) -> DispatchPlan {
    let usable = tiers.filter(\.availability.isAvailable)
    let picked = query.targetBackendSyncID.map { id in usable.first { $0.backendSyncID == id } } ?? usable.first
    let cwd = query.projectSyncID.map { "/srv/\($0)" } ?? ""
    return DispatchPlan(agentSyncID: query.agentSyncID, tiers: tiers, chosen: picked.map { choice($0.deviceName, backend: $0.backendSyncID, cwd: cwd) })
}

// MARK: 伪端口

actor FakeWorkspace: WorkspaceService {
    var agentList: [WorkspaceAgent]
    var projectList: [WorkspaceProject]
    var planner: @Sendable (DispatchPlanQuery) -> DispatchPlan
    private(set) var planQueries: [DispatchPlanQuery] = []
    var failAgents = false
    var failPlans = false
    var failProjects = false
    /// 挂住下一次取计划，直到 `releasePlan()`：用来验证在飞与过时的应答。
    var holdNextPlan = false
    private var planGate: CheckedContinuation<Void, Never>?

    init(agents: [WorkspaceAgent] = [], projects: [WorkspaceProject] = projectTree, planner: @escaping @Sendable (DispatchPlanQuery) -> DispatchPlan = plan(for:)) {
        agentList = agents
        projectList = projects
        self.planner = planner
    }

    func configure(failAgents: Bool = false, failPlans: Bool = false, failProjects: Bool = false, holdNextPlan: Bool = false) {
        self.failAgents = failAgents
        self.failPlans = failPlans
        self.failProjects = failProjects
        self.holdNextPlan = holdNextPlan
    }

    func set(planner: @escaping @Sendable (DispatchPlanQuery) -> DispatchPlan) { self.planner = planner }
    func set(projects: [WorkspaceProject]) { projectList = projects }

    var isHoldingPlan: Bool { planGate != nil }
    func releasePlan() { planGate?.resume(); planGate = nil }

    func agents() throws -> [WorkspaceAgent] {
        if failAgents { throw AuthError.unexpectedResponse(status: 500) }
        return agentList
    }

    func projects() throws -> [WorkspaceProject] {
        if failProjects { throw AuthError.unexpectedResponse(status: 500) }
        return projectList
    }

    func dispatchPlan(_ query: DispatchPlanQuery) async throws -> DispatchPlan {
        planQueries.append(query)
        if holdNextPlan {
            holdNextPlan = false
            await withCheckedContinuation { planGate = $0 }
        }
        if failPlans { throw AuthError.unexpectedResponse(status: 500) }
        return planner(query)
    }
}

actor FakeDispatcher: NewConversationDispatching {
    private(set) var requests: [DispatchRequest] = []
    var failure: DispatchFailure?
    /// 派发收尾钉住的结果；缺省两项都钉住了。
    var pins = DispatchPins()

    func fail(with failure: DispatchFailure?) { self.failure = failure }
    func setPins(_ pins: DispatchPins) { self.pins = pins }

    func dispatch(_ request: DispatchRequest) throws -> DispatchPins {
        requests.append(request)
        if let failure { throw failure }
        return pins
    }
}

let sampleToolOptions = DraftToolOptions(
    permissionModes: ["default", "acceptEdits", "plan"],
    models: [
        ComposerModelChoice(providerKey: "anthropic", modelKey: "sonnet", modelId: "claude-sonnet", name: "Sonnet", providerName: "Anthropic"),
        ComposerModelChoice(providerKey: "anthropic", modelKey: "opus", modelId: "claude-opus", name: "Opus", providerName: "Anthropic"),
    ]
)

/// 草稿工具行的候选：记下问的是哪一档，答回固定的一份。
actor FakeToolOptions: DraftToolOptionsSource {
    private(set) var queries: [DispatchChoice] = []
    /// 按机器名给的答复；没配的那台答 `sampleToolOptions`。
    var answers: [String: DraftToolOptions] = [:]
    private var holdNext = false
    private var gate: CheckedContinuation<Void, Never>?

    func set(_ options: DraftToolOptions, for machine: String) { answers[machine] = options }
    /// 挂住下一次问询，直到 `release()`：用来验证换了机器之后才到的旧应答。
    func holdNextQuery() { holdNext = true }
    var isHolding: Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }

    func options(for target: DispatchChoice) async -> DraftToolOptions {
        queries.append(target)
        let answer = answers[target.deviceName] ?? sampleToolOptions
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        return answer
    }
}

struct RecordFailed: Error {}

actor FakeRecorder: StartedConversationRecording {
    private(set) var recorded: [StartedConversation] = []
    var failuresLeft = 0

    func failNext(_ count: Int) { failuresLeft = count }

    func record(_ conversation: StartedConversation) throws -> ConversationKey {
        recorded.append(conversation)
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw RecordFailed()
        }
        return ConversationKey(machineFingerprint: conversation.machineFingerprint, conversationID: conversation.conversationID)
    }
}

/// 落到真实本地库的记录器：与装配层的适配器同形（新建的对话以一份清单快照认领进库）。
struct StoreRecorder: StartedConversationRecording {
    let store: LocalConversationStore

    func record(_ conversation: StartedConversation) async throws -> ConversationKey {
        var summary = Agentre_Wire_SessionSummary()
        summary.conversationID = conversation.conversationID
        summary.title = conversation.title
        summary.agentSyncID = conversation.agentSyncID
        summary.projectSyncID = conversation.projectSyncID
        summary.cwd = conversation.cwd
        summary.backendType = conversation.backendType
        summary.lifecycleState = SavedConversation.Lifecycle.running
        return try await store.save(summary, via: conversation.machineFingerprint)
    }
}

/// 伪本地库：「最近用过」从这里读。
actor FakeConversationStore: ConversationStore {
    private var rows: [SavedConversation]

    init(_ rows: [SavedConversation] = []) { self.rows = rows }

    func conversations() -> [SavedConversation] { rows }
    func conversation(_ key: ConversationKey) -> SavedConversation? { rows.first { $0.key == key } }
    func transcript(_ key: ConversationKey) -> [TranscriptFrame] { [] }
    func latestSeq(_ key: ConversationKey) -> Int64 { 0 }
    func markRead(_ key: ConversationKey) {}
    func delete(_ key: ConversationKey) { rows.removeAll { $0.key == key } }
    func removeAll() { rows = [] }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

func saved(_ id: String, agent: String, last: Int64) -> SavedConversation {
    SavedConversation(key: ConversationKey(machineFingerprint: "fp", conversationID: id), agentSyncID: agent, lastMessageAt: last)
}

/// 一个真实的临时目录，测试结束时删掉。
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "AgentreNewConversationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor
func draft(
    agent: WorkspaceAgent = agent("coder"),
    project: WorkspaceProject? = nil,
    workspace: FakeWorkspace = FakeWorkspace(),
    dispatcher: any NewConversationDispatching = FakeDispatcher(),
    recorder: any StartedConversationRecording = FakeRecorder(),
    options: any DraftToolOptionsSource = FakeToolOptions(),
    id: String = "0199aaaa-0000-7000-8000-000000000001"
) -> DraftConversationModel {
    DraftConversationModel(
        agent: agent, project: project, projects: projectTree,
        workspace: workspace, dispatcher: dispatcher, recorder: recorder, toolOptions: options, mintID: { id }
    )
}

/// 表现层字符串表里一个键此刻解析出的文字。
func text(_ key: String, _ arguments: CVarArg...) -> String {
    let format = AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "NewConversation")
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}

/// 某语言下的译文（直接读那一份 lproj）。
func text(_ key: String, table: String = "NewConversation", language: String) throws -> String {
    let path = try #require(AgentreUIResources.bundle.path(forResource: language, ofType: "lproj"))
    return try #require(Bundle(path: path)).localizedString(forKey: key, value: "⟨missing⟩", table: table)
}

/// 等一个条件成立（真实时间上限 3 秒）。
@MainActor
func eventually(_ what: String = "condition", sourceLocation: SourceLocation = #_sourceLocation, _ probe: @MainActor () async -> Bool) async throws {
    for _ in 0..<3000 {
        if await probe() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    throw CancellationError()
}

enum LocalConversationStoreBox {
    static func open(_ directory: TemporaryDirectory) throws -> LocalConversationStore {
        try LocalConversationStore(directory: directory.url)
    }
}
