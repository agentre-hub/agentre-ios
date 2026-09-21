import AgentreDomain
@testable import AgentreUI
import Foundation
import Testing

// MARK: 样本

let key = ConversationKey(machineFingerprint: "fp-mini", conversationID: "conv-1")

func conversation(backend: String = "claudecode", cwd: String = "/srv/app") -> SavedConversation {
    SavedConversation(key: key, peerFingerprint: "fp-desk", title: "修构建", agentSyncID: "coder", cwd: cwd, backendType: backend)
}

let sampleSettings = ComposerSettings(
    permissionMode: "acceptEdits",
    permissionModes: ["default", "acceptEdits", "plan"],
    model: ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-sonnet"),
    models: [ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-sonnet"), ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus")],
    reasoningEffort: "",
    backendReasoningEffort: "high"
)

// MARK: 伪端口

/// 记下每一次中继调用；应答可按方法预设。
actor FakeComposerRelay: ComposerRelay {
    enum Call: Equatable {
        case run(String, compact: Bool)
        case steer(queuedID: String, text: String)
        case cancel(String)
        case drain
        case permission(String)
        case model(String, String)
        case effort(String)
        case delete
        case skills(machine: String, backend: String, cwd: String)
    }

    private(set) var calls: [Call] = []
    var steerHandle: (@Sendable (String) -> ComposerSteerHandle)? = { ComposerSteerHandle(queuedID: "exec-\($0)", cancellable: true) }
    var drained: [ComposerConsumedSteer]? = []
    var skills: [ComposerSkillSource] = []
    var failing: Set<String> = []

    func set(drained: [ComposerConsumedSteer]?) { self.drained = drained }
    func set(skills: [ComposerSkillSource]) { self.skills = skills }
    func fail(_ method: String) { failing.insert(method) }
    func set(steerHandle: (@Sendable (String) -> ComposerSteerHandle)?) { self.steerHandle = steerHandle }

    private func check(_ method: String) throws {
        if failing.contains(method) { throw URLError(.notConnectedToInternet) }
    }

    func run(_ key: ConversationKey, peerFingerprint: String, text: String, compact: Bool) async throws {
        calls.append(.run(text, compact: compact))
        try check("run")
    }

    func steer(_ key: ConversationKey, peerFingerprint: String, queuedID: String, text: String) async throws -> ComposerSteerHandle {
        calls.append(.steer(queuedID: queuedID, text: text))
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
        try check("drain")
        return drained
    }

    func setPermissionMode(_ key: ConversationKey, peerFingerprint: String, mode: String) async throws {
        calls.append(.permission(mode))
        try check("permission")
    }

    func setModelTarget(_ key: ConversationKey, peerFingerprint: String, providerKey: String, modelKey: String) async throws {
        calls.append(.model(providerKey, modelKey))
        try check("model")
    }

    func setReasoningEffort(_ key: ConversationKey, peerFingerprint: String, effort: String) async throws {
        calls.append(.effort(effort))
        try check("effort")
    }

    func deleteSession(_ key: ConversationKey, peerFingerprint: String) async throws -> Bool {
        calls.append(.delete)
        try check("delete")
        return true
    }

    func skillCommands(machineFingerprint: String, agentSyncID: String, backendType: String, cwd: String) async throws -> [ComposerSkillSource] {
        calls.append(.skills(machine: machineFingerprint, backend: backendType, cwd: cwd))
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
    func conversations() -> [SavedConversation] { [] }
    func conversation(_ key: ConversationKey) -> SavedConversation? { nil }
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
    relay: FakeComposerRelay = FakeComposerRelay(),
    store: FakeConversationStore = FakeConversationStore(),
    settings: FakeSettingsSource = FakeSettingsSource(),
    mentions: FakeMentionSource = FakeMentionSource()
) -> ComposerModel {
    var counter = 0
    return ComposerModel(
        conversation: conversation(backend: backend), relay: relay, settingsSource: settings, mentionSource: mentions, store: store,
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
