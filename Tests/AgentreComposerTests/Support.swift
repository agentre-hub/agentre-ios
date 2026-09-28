import AgentreDomain
@testable import AgentreUI
import Foundation
import Testing

// MARK: 样本

let key = ConversationKey(machineFingerprint: "fp-mini", conversationID: "conv-1")

func conversation(
    backend: String = "claudecode", cwd: String = "/srv/app", providerKey: String = "", modelKey: String = "", reasoningEffort: String = ""
) -> SavedConversation {
    SavedConversation(
        key: key, carrierFingerprint: "fp-mini", peerFingerprint: "fp-desk", title: "修构建", agentSyncID: "coder", cwd: cwd, backendType: backend,
        providerKey: providerKey, modelKey: modelKey, reasoningEffort: reasoningEffort
    )
}

let sampleSettings = ComposerSettings(
    permissionMode: "acceptEdits",
    permissionModes: ["default", "acceptEdits", "plan"],
    model: ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-sonnet"),
    models: [ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-sonnet"), ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus")],
    reasoningEffort: "high"
)

/// 引擎目录的真实形状：modelKey 是 UUID 形的稳定键，人读的是 name（缺了回落 modelId）；
/// 两家供应商下各有一个叫 Opus 的模型（运行验证 evidence-3/72-model 的现场即逐行 UUID）。
let namedCatalog = [
    ComposerModelChoice(
        providerKey: "anthropic", modelKey: "9f1c2e7a-0000-4000-8000-000000000001", modelId: "claude-opus-4-1", name: "Opus",
        providerName: "Anthropic"
    ),
    ComposerModelChoice(
        providerKey: "anthropic", modelKey: "9f1c2e7a-0000-4000-8000-000000000002", modelId: "claude-sonnet-4-5", providerName: "Anthropic"
    ),
    ComposerModelChoice(providerKey: "relay", modelKey: "9f1c2e7a-0000-4000-8000-000000000003", providerName: "Relay"),
    ComposerModelChoice(
        providerKey: "relay", modelKey: "9f1c2e7a-0000-4000-8000-000000000004", modelId: "claude-opus-4-1", name: "Opus", providerName: "Relay"
    ),
]

// MARK: 伪端口

/// 记下每一次中继调用；应答可按方法预设。
///
/// 控制面照搬 agentred：会话只在一轮跑着时登记（run 登记、`finishTurn()` 摘掉），不在时
/// setPermissionMode 回「没有进行中的一轮」（agentre/internal/daemon/handlers/runtime.go:1454-1462、:1682-1689）。
/// 执行进程照搬 claudecode 的进程池：没有活着的进程时 run 按它带的档起一个；进程还在（闲置 15 分钟内）时原样复用，
/// run 带来的新档不生效，只有一轮登记着时的 setPermissionMode 才改它（claudecode/runtime.go:620-626、:342-357）。
/// 模型与思考档位照搬 agentred：执行只认 run 带的那几格（agentre/internal/daemon/handlers/runtime.go:384-385、:449-453；
/// 两者都在 launchIdentity 里，变了就另起进程），setModelTarget / setReasoningEffort 只改会话行上显示的值。
actor FakeComposerRelay: ComposerRelay {
    /// agentruntime.ErrNoActiveTurn 的替身。
    struct NoActiveTurn: Error {}

    enum Call: Equatable {
        case run(String, compact: Bool)
        case abort
        case steer(queuedID: String, text: String)
        case cancel(String)
        case drain
        case permission(String)
        case model(String, String)
        case effort(String)
        case delete
        case skills(ConversationKey, backend: String, cwd: String)
    }

    private(set) var calls: [Call] = []
    /// 每一轮 run 带过去的设定，按调用次序。
    private(set) var runSettings: [ComposerRunSettings] = []
    /// 每一轮 run 带过去的权限档位，按调用次序。
    var runPermissionModes: [String] { runSettings.map(\.permissionMode) }
    /// 最近一轮机器实际用的模型目标（两枚键都空 = 跟随 Agent 绑定）与思考档位（空 = 后端配置）；还没跑过为 nil。
    private(set) var effectiveModel: ComposerModelChoice?
    private(set) var effectiveEffort: String?
    /// 会话行上记下的模型目标与思考档位：只供显示，执行不看它。
    private(set) var storedModel: ComposerModelChoice?
    private(set) var storedEffort: String?
    /// 执行端此刻登记着一轮在跑。
    private(set) var activeTurn = false
    /// 这条会话的执行进程此刻实际按哪一档跑；nil = 没有活着的进程。
    private(set) var executorMode: String?
    var steerHandle: (@Sendable (String) -> ComposerSteerHandle)? = { ComposerSteerHandle(queuedID: "exec-\($0)", cancellable: true) }
    var drained: [ComposerConsumedSteer]? = []
    var skills: [ComposerSkillSource] = []
    var failing: Set<String> = []
    /// run 的收场：默认应答到了；`.confirmed` = 应答丢了、回头问机器才知道它受理了。
    var runReceipt = ComposerRunReceipt.acknowledged

    func set(drained: [ComposerConsumedSteer]?) { self.drained = drained }
    func set(runReceipt: ComposerRunReceipt) { self.runReceipt = runReceipt }
    func set(skills: [ComposerSkillSource]) { self.skills = skills }
    func fail(_ method: String) { failing.insert(method) }
    func succeed(_ method: String) { failing.remove(method) }
    func set(steerHandle: (@Sendable (String) -> ComposerSteerHandle)?) { self.steerHandle = steerHandle }
    /// 执行端登记一轮（别的端开的也算）。
    func startTurn() { activeTurn = true }
    /// 这一轮收场：执行端把会话从内存表里摘掉。
    func finishTurn() { activeTurn = false }
    /// 池里已有一个按 `mode` 起的执行进程（别的端开的、或 App 重启之前那一次）。
    func launchExecutor(mode: String) { executorMode = mode }

    private func check(_ method: String) throws {
        if failing.contains(method) { throw URLError(.notConnectedToInternet) }
    }

    func run(_ key: ConversationKey, peerFingerprint: String, text: String, compact: Bool, settings: ComposerRunSettings) async throws -> ComposerRunReceipt {
        calls.append(.run(text, compact: compact))
        runSettings.append(settings)
        let permissionMode = settings.permissionMode
        if holdRun {
            holdRun = false
            await withCheckedContinuation { runGate = $0 }
        }
        try check("run")
        activeTurn = true
        if executorMode == nil { executorMode = permissionMode.isEmpty ? "default" : permissionMode }
        effectiveModel = ComposerModelChoice(providerKey: settings.providerKey, modelKey: settings.modelKey)
        effectiveEffort = settings.reasoningEffort
        return runReceipt
    }

    func abort(_ key: ConversationKey, peerFingerprint: String) async throws {
        calls.append(.abort)
        if holdAbort {
            holdAbort = false
            await withCheckedContinuation { abortGate = $0 }
        }
        try check("abort")
    }

    /// 下一次停止挂起，直到 `releaseAbort()`：观察停的调用在飞的那一段。
    private var holdAbort = false
    private var abortGate: CheckedContinuation<Void, Never>?
    func holdNextAbort() { holdAbort = true }
    func releaseAbort() { abortGate?.resume(); abortGate = nil }
    nonisolated func waitForHeldAbort() async {
        for _ in 0..<3_000 where await abortGate == nil { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func steer(_ key: ConversationKey, peerFingerprint: String, queuedID: String, text: String) async throws -> ComposerSteerHandle {
        calls.append(.steer(queuedID: queuedID, text: text))
        if holdSteer {
            holdSteer = false
            await withCheckedContinuation { steerGate = $0 }
        }
        try check("steer")
        return steerHandle?(queuedID) ?? ComposerSteerHandle(queuedID: "", cancellable: false)
    }

    func cancelSteer(_ key: ConversationKey, peerFingerprint: String, queuedID: String) async throws -> [String] {
        calls.append(.cancel(queuedID))
        try check("cancel")
        return [queuedID]
    }

    func drainPending(_ key: ConversationKey, peerFingerprint: String) async throws -> [ComposerConsumedSteer]? {
        calls.append(.drain)
        if holdDrain {
            holdDrain = false
            await withCheckedContinuation { drainGate = $0 }
        }
        try check("drain")
        return drained
    }

    /// 下一次信箱这一问挂起，直到 `releaseDrain()`：观察轮末接续在路上的那一段。
    private var holdDrain = false
    private var drainGate: CheckedContinuation<Void, Never>?
    func holdNextDrain() { holdDrain = true }
    func releaseDrain() { drainGate?.resume(); drainGate = nil }
    nonisolated func waitForHeldDrain() async {
        for _ in 0..<3_000 where await drainGate == nil { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// 下一次插话挂起，直到 `releaseSteer()`：观察插话在飞时这一轮收场的那一段。
    private var holdSteer = false
    private var steerGate: CheckedContinuation<Void, Never>?
    func holdNextSteer() { holdSteer = true }
    func releaseSteer() { steerGate?.resume(); steerGate = nil }
    nonisolated func waitForHeldSteer() async {
        for _ in 0..<3_000 where await steerGate == nil { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// 下一次开新一轮挂起，直到 `releaseRun()`：观察开新一轮的调用在飞的那一段。
    private var holdRun = false
    private var runGate: CheckedContinuation<Void, Never>?
    func holdNextRun() { holdRun = true }
    func releaseRun() { runGate?.resume(); runGate = nil }
    nonisolated func waitForHeldRun() async {
        for _ in 0..<3_000 where await runGate == nil { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func setPermissionMode(_ key: ConversationKey, peerFingerprint: String, mode: String) async throws {
        calls.append(.permission(mode))
        let refusal: (any Error)? = failing.contains("permission") ? URLError(.notConnectedToInternet) : activeTurn ? nil : NoActiveTurn()
        if refusal == nil { executorMode = mode }
        if holdingPermissions { await withCheckedContinuation { permissionGates.append($0) } }
        if let refusal { throw refusal }
    }

    /// 此后换成了的档照到达次序在执行端生效（没成的那一次不生效），应答（连同没成的那一次的失败）挂起：`releasePermission()` 按次序放回最早的一个，
    /// `releasePermissions()` 放回全部、不再挂起。观察补发（与切档）的应答在路上的那一段。
    private var holdingPermissions = false
    private var permissionGates: [CheckedContinuation<Void, Never>] = []
    func holdPermissions() { holdingPermissions = true }
    func releasePermission() { if !permissionGates.isEmpty { permissionGates.removeFirst().resume() } }
    /// 放回最晚挂起的那一个（后发的应答先到）。
    func releaseLatestPermission() { if !permissionGates.isEmpty { permissionGates.removeLast().resume() } }
    func releasePermissions() {
        holdingPermissions = false
        permissionGates.forEach { $0.resume() }
        permissionGates = []
    }
    var heldPermissions: Int { permissionGates.count }

    func setModelTarget(_ key: ConversationKey, peerFingerprint: String, providerKey: String, modelKey: String) async throws {
        calls.append(.model(providerKey, modelKey))
        try check("model")
        storedModel = ComposerModelChoice(providerKey: providerKey, modelKey: modelKey)
    }

    func setReasoningEffort(_ key: ConversationKey, peerFingerprint: String, effort: String) async throws {
        calls.append(.effort(effort))
        try check("effort")
        storedEffort = effort
    }

    func deleteSession(_ key: ConversationKey, peerFingerprint: String) async throws -> Bool {
        calls.append(.delete)
        try check("delete")
        return true
    }

    func skillCommands(_ key: ConversationKey, agentSyncID: String, backendType: String, cwd: String) async throws -> [ComposerSkillSource] {
        calls.append(.skills(key, backend: backendType, cwd: cwd))
        try check("skills")
        return skills
    }
}

struct FakeSettingsSource: ComposerSettingsSource {
    var settings = sampleSettings
    func settings(for conversation: SavedConversation) async throws -> ComposerSettings { settings }
}

struct FakeMentionSource: ComposerMentionSource {
    var sources = ComposerMentionSources(
        agents: [ComposerMentionAgent(id: 7, name: "reviewer"), ComposerMentionAgent(id: 8, name: "writer")],
        devices: [ComposerMentionDevice(fingerprint: "fp-studio", name: "studio", online: false)]
    )
    func mentionSources() async throws -> ComposerMentionSources { sources }
}

actor FakeConversationStore: ConversationStore {
    private(set) var deleted: [ConversationKey] = []
    /// 库里这条会话此刻的那一行（跟随重新接上时按机器清单刷新）；nil = 不在库里。
    private var row: SavedConversation?
    func set(row: SavedConversation?) { self.row = row }
    func conversations() -> [SavedConversation] { [] }
    func conversation(_ key: ConversationKey) -> SavedConversation? { row }
    func transcript(_ key: ConversationKey) -> [TranscriptFrame] { [] }
    func latestSeq(_ key: ConversationKey) -> Int64 { 0 }
    func markRead(_ key: ConversationKey) {}
    func delete(_ key: ConversationKey) { deleted.append(key) }
    func removeAll() {}
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

@MainActor
func composer(
    backend: String = "claudecode",
    saved: SavedConversation? = nil,
    relay: FakeComposerRelay = FakeComposerRelay(),
    store: FakeConversationStore = FakeConversationStore(),
    settings: FakeSettingsSource = FakeSettingsSource(),
    mentions: FakeMentionSource = FakeMentionSource()
) -> ComposerModel {
    var counter = 0
    return ComposerModel(
        conversation: saved ?? conversation(backend: backend), relay: relay, settingsSource: settings, mentionSource: mentions, store: store,
        mintID: { counter += 1; return "local-\(counter)" }
    )
}

func text(_ key: String, _ arguments: CVarArg...) -> String {
    let format = AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Composer")
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
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
