import AgentreDomain
import Foundation
import Observation

/// 一条还没发出第一条消息的对话。机器与项目两枚 chip 在这里定；机器是对该 Agent 执行目标链
/// 的覆盖，只活在这个模型里——不写回 Agent 的配置，下一条新对话照旧按次序自动挑。
@MainActor
@Observable
public final class DraftConversationModel {
    public enum Phase: Equatable {
        case draft
        /// 第一条消息在飞。
        case sending
        /// 派发没成：这条对话没建起来，话还在输入框里。
        case dispatchFailed(DispatchFailure, machine: String)
        /// 已经在机器上跑起来了，但没能落进本地库：可重试落库，不再派发。
        case notListed(StartedConversation)
        /// 跑起来且已入列。
        case started(ConversationKey)
    }

    /// 机器 chip 此刻说什么。
    public enum MachineChip: Equatable {
        case resolving
        case machine(String)
        /// 选中的（或按次序挑的）档跑不了，给出具体原因。
        case unavailable(TargetAvailability)
        case noTarget
        case planFailed
    }

    public let agent: WorkspaceAgent
    public let projects: [WorkspaceProject]
    public private(set) var project: WorkspaceProject?
    public private(set) var plan: DispatchPlan?
    /// 手动指定的那一档；nil = 按次序自动挑。
    public private(set) var manualTarget: String?
    public private(set) var phase: Phase = .draft
    public private(set) var planFailed = false
    /// 已经发出（或正在发）的第一条消息；派发没成时收回。
    public private(set) var sentText: String?
    public var text = ""

    private let workspace: any WorkspaceService
    private let dispatcher: any NewConversationDispatching
    private let recorder: any StartedConversationRecording
    private let mintID: @Sendable () -> String
    /// 每次重算计划加一；过时的应答不落。
    private var planGeneration = 0
    /// 最新一次重算还在飞：手里那份计划是换项目 / 换机器之前的，不能拿它派发。
    private var isResolving = false
    /// 重试落库在飞：连点不重复落。
    private var isRecording = false

    public init(
        agent: WorkspaceAgent, project: WorkspaceProject?, projects: [WorkspaceProject],
        workspace: any WorkspaceService, dispatcher: any NewConversationDispatching, recorder: any StartedConversationRecording,
        mintID: @escaping @Sendable () -> String = { ConversationIDs.mint() }
    ) {
        self.agent = agent
        self.project = project
        self.projects = projects
        self.workspace = workspace
        self.dispatcher = dispatcher
        self.recorder = recorder
        self.mintID = mintID
    }

    public var machineChip: MachineChip {
        if isResolving { return .resolving }
        if planFailed { return .planFailed }
        guard let plan else { return .resolving }
        if let chosen = plan.chosen { return .machine(chosen.deviceName) }
        let blocking = manualTarget.flatMap { id in plan.tiers.first { $0.backendSyncID == id } }
            ?? plan.tiers.first { !$0.availability.isAvailable }
        return blocking.map { .unavailable($0.availability) } ?? .noTarget
    }

    /// 发出第一条消息之后 chip 行退场；派发没成时这条对话还没开始，chip 行留着。
    public var showsChips: Bool {
        switch phase {
        case .draft, .dispatchFailed: true
        case .sending, .notListed, .started: false
        }
    }

    public var canSend: Bool {
        showsChips && !isResolving && plan?.chosen != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func loadPlan() async {
        planGeneration += 1
        let generation = planGeneration
        isResolving = true
        let query = DispatchPlanQuery(agentSyncID: agent.syncID, projectSyncID: project?.syncID, targetBackendSyncID: manualTarget)
        let result: Result<DispatchPlan, any Error>
        do {
            result = .success(try await workspace.dispatchPlan(query))
        } catch {
            result = .failure(error)
        }
        guard generation == planGeneration else { return }
        isResolving = false
        switch result {
        case .success(let fresh):
            plan = fresh
            planFailed = false
        case .failure:
            plan = nil
            planFailed = true
        }
    }

    /// 手动指定一档。不可用的档列出但挑不了。
    public func pick(_ tier: DispatchTier) async {
        guard showsChips, tier.availability.isAvailable, !tier.backendSyncID.isEmpty else { return }
        manualTarget = tier.backendSyncID
        await loadPlan()
    }

    public func useAutomatic() async {
        guard showsChips, manualTarget != nil else { return }
        manualTarget = nil
        await loadPlan()
    }

    /// 换项目（nil = 不指定项目）：工作目录随之变，逐档重算。
    public func choose(_ project: WorkspaceProject?) async {
        guard showsChips else { return }
        self.project = project
        await loadPlan()
    }

    /// 发出第一条消息：以手机铸的号派发到选中那台机器，成功后立即落进本地库。
    public func send() async {
        guard canSend, let target = plan?.chosen else { return }
        let userText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = DispatchRequest(
            conversationID: mintID(), title: conversationTitle(from: userText), userText: userText,
            agentSyncID: agent.syncID, projectSyncID: project?.syncID, target: target
        )
        phase = .sending
        sentText = userText
        do {
            try await dispatcher.dispatch(request)
        } catch {
            sentText = nil
            phase = .dispatchFailed(error as? DispatchFailure ?? .rejected, machine: target.deviceName)
            return
        }
        text = ""
        await record(StartedConversation(request: request))
    }

    /// 已开始但未入列时重试落库。不再派发：那台机器上已经有这条会话了。
    public func retryRecording() async {
        guard case .notListed(let started) = phase, !isRecording else { return }
        isRecording = true
        defer { isRecording = false }
        await record(started)
    }

    private func record(_ started: StartedConversation) async {
        do {
            phase = .started(try await recorder.record(started))
        } catch {
            phase = .notListed(started)
        }
    }
}
