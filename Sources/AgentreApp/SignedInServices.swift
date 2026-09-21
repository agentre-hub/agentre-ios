import AgentreDomain
import AgentreRelay
import AgentreREST
import AgentreStore
import AgentreUI
import Foundation
import Observation

/// 消息标签里的去处。
enum MessagesRoute: Hashable {
    case conversation(ConversationKey)
    case newConversation
    case projects
    case project(String)
    case draft(agent: String, project: String?)
}

/// 机器标签里的去处。
enum MachinesRoute: Hashable {
    case machine(String)
    case conversation(ConversationKey)
}

/// 两个导航栈的路径。
@MainActor
@Observable
final class Router {
    var messages: [MessagesRoute] = []
    var machines: [MachinesRoute] = []
}

/// 一条会话打开后的全部状态：转录、这条会话唯一的一份卡片状态、输入区。
@MainActor
final class ConversationScreenModel {
    let conversation: SavedConversation
    let transcript: TranscriptModel
    let cards: ApprovalCardsModel
    let composer: ComposerModel
    let agentName: String

    init(conversation: SavedConversation, transcript: TranscriptModel, cards: ApprovalCardsModel, composer: ComposerModel, agentName: String) {
        self.conversation = conversation
        self.transcript = transcript
        self.cards = cards
        self.composer = composer
        self.agentName = agentName
    }

    /// 转录实时帧里的回合事件递给输入区。
    func apply(_ signal: TurnSignal) async {
        switch signal {
        case .started: composer.turnStarted()
        case .ended(let normally): await composer.turnEnded(normally: normally)
        case .steersConsumed(let consumed): composer.steersConsumed(consumed)
        }
    }
}

/// 登录态里的那一套：此刻服务器上的 REST 客户端、账号唯一一条中继连接、各屏的中继适配器与模型。
/// 手机上的会话通道一律是 `machine:<承载机>`，承载机取自本地库记下的那台（不是会话键上的发起端）。
@MainActor
@Observable
final class SignedInServices {
    @ObservationIgnored let store: LocalConversationStore
    @ObservationIgnored let connection: RelayConnection
    @ObservationIgnored let carrier: RelayCarrier
    @ObservationIgnored let machineSessions: RelayMachineSessions
    @ObservationIgnored let transfer: RewindingTransfer
    @ObservationIgnored let approvals: RelayApprovalAnswering
    @ObservationIgnored let composerRelay: RelayComposer
    @ObservationIgnored let dispatcher: RelayDispatcher
    @ObservationIgnored let workspace: WorkspaceClient
    @ObservationIgnored let machineDirectory: MachineDirectory
    @ObservationIgnored let mentions: RESTMentionSource
    @ObservationIgnored let settings: ComposerSettingsAdapter
    @ObservationIgnored let sync: ConversationSync
    @ObservationIgnored let messages: MessagesModel
    @ObservationIgnored let machines: MachinesModel
    @ObservationIgnored let newConversation: NewConversationModel
    @ObservationIgnored let me: MeModel
    let router = Router()
    /// 跟随不上的会话与其事实（对话屏据此如实说出来）。
    let failures: SyncFailures

    @ObservationIgnored private var conversations: [ConversationKey: ConversationScreenModel] = [:]
    @ObservationIgnored private var details: [String: MachineDetailModel] = [:]
    @ObservationIgnored private var drafts: [MessagesRoute: DraftConversationModel] = [:]
    @ObservationIgnored private var agentNames: [String: String] = [:]
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        let dependencies = environment.dependencies
        let store = environment.store
        let server = dependencies.servers.load()
        let tokens = environment.tokens
        self.store = store
        me = environment.me
        connection = RelayConnection(
            url: RelayEndpoint.clientURL(for: server), dialer: dependencies.relayDialer,
            accessToken: { try await tokens.accessToken() }, sleeper: dependencies.relaySleeper
        )
        let carrier: RelayCarrier = { key in (try? await store.carrier(of: key)) ?? key.machineFingerprint }
        self.carrier = carrier
        let source = RelaySourceDevice(
            fingerprint: (try? dependencies.credentials.deviceFingerprint().value) ?? "", name: dependencies.deviceName
        )
        machineSessions = RelayMachineSessions(connection: connection)
        transfer = RewindingTransfer(inner: machineSessions, store: store)
        approvals = RelayApprovalAnswering(connection: connection, carrier: carrier)
        let roster = MachineRosterClient(transport: environment.transport, server: server)
        let directory = MachineDirectory(roster: roster)
        machineDirectory = directory
        composerRelay = RelayComposer(
            connection: connection, source: source, carrier: carrier,
            conversation: { key in try? await store.conversation(key) },
            machineKind: { fingerprint in await directory.kind(of: fingerprint) },
            // Skill 授权是组织数据，设备令牌能读的 REST 面上没有它：按空授权问，机器仍答得出它自己解析的那一半。
            skillGrants: { _, _, _ in [] }
        )
        dispatcher = RelayDispatcher(connection: connection, source: source)
        workspace = WorkspaceClient(transport: environment.transport, server: server)
        mentions = RESTMentionSource(workspace: workspace, machines: directory)
        settings = ComposerSettingsAdapter(
            catalog: EngineCatalogClient(transport: environment.transport, server: server), connection: connection, carrier: carrier
        )
        messages = MessagesModel(store: store)
        machines = MachinesModel(roster: roster)
        newConversation = NewConversationModel(workspace: workspace, store: store)
        let failures = SyncFailures()
        self.failures = failures
        sync = ConversationSync(connection: connection, store: store) { key, fact in await failures.set(fact, for: key) }
    }

    func start() {
        guard syncTask == nil else { return }
        let connection = connection
        let sync = sync
        syncTask = Task {
            await connection.start()
            await sync.run()
        }
        Task { [weak self] in await self?.loadAgentNames() }
    }

    /// 回到前台、或用户点了重试：补上没在跟随的会话（连接自己会重拨）。
    func resume() async {
        await sync.resync()
    }

    func stop() async {
        syncTask?.cancel()
        syncTask = nil
        await sync.stop()
        await connection.stop()
    }

    private func loadAgentNames() async {
        guard let agents = try? await workspace.agents() else { return }
        agentNames = Dictionary(agents.map { ($0.syncID, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: 各屏的模型（同一去处只建一次）

    /// 已经打开过的那一份（不去库里读）。
    func openConversation(_ key: ConversationKey) -> ConversationScreenModel? {
        conversations[key]
    }

    /// 一条会话的对话屏。每条会话只有一份卡片状态与输入区，重复进入拿到的是同一份。
    func conversationModel(for key: ConversationKey) async -> ConversationScreenModel? {
        if let cached = conversations[key] { return cached }
        guard let conversation = try? await store.conversation(key) else { return nil }
        if let cached = conversations[key] { return cached }
        let store = store
        let box = WeakScreen()
        let transcript = TranscriptModel(
            conversation: conversation, store: store,
            relay: TurnFeedingTranscript(
                inner: RelayTranscript(
                    connection: connection, carrier: carrier,
                    localCursor: { key in (try? await store.latestSeq(key)) ?? 0 }
                ),
                feed: { signal in await box.apply(signal) }
            ),
            decoder: WireTranscriptDecoder()
        )
        let composer = ComposerModel(
            conversation: conversation, relay: composerRelay, settingsSource: settings, mentionSource: mentions, store: store
        )
        if conversation.lifecycleState == SavedConversation.Lifecycle.running { composer.turnStarted() }
        let screen = ConversationScreenModel(
            conversation: conversation, transcript: transcript,
            cards: ApprovalCardsModel(conversation: conversation, answering: approvals),
            composer: composer,
            agentName: agentNames[conversation.agentSyncID] ?? conversation.backendType
        )
        box.screen = screen
        conversations[key] = screen
        return screen
    }

    /// 会话删掉了：丢掉它的屏状态。
    func forget(_ key: ConversationKey) {
        conversations[key] = nil
    }

    func machine(_ fingerprint: String) -> Machine? {
        machines.machines.first { $0.fingerprint == fingerprint }
    }

    func detailModel(for machine: Machine) -> MachineDetailModel {
        if let cached = details[machine.fingerprint], cached.machine == machine { return cached }
        let model = MachineDetailModel(machine: machine, sessions: machineSessions, store: store, transfer: transfer)
        details[machine.fingerprint] = model
        return model
    }

    func draftModel(for route: MessagesRoute) -> DraftConversationModel? {
        guard case .draft(let agentID, let projectID) = route else { return nil }
        if let cached = drafts[route] { return cached }
        guard let agent = newConversation.agents.first(where: { $0.syncID == agentID }) else { return nil }
        let projects = newConversation.projects
        let model = DraftConversationModel(
            agent: agent, project: projectID.flatMap { id in projects.first { $0.syncID == id } }, projects: projects,
            workspace: workspace, dispatcher: dispatcher, recorder: store
        )
        drafts[route] = model
        return model
    }

    func project(_ syncID: String) -> WorkspaceProject? {
        newConversation.projects.first { $0.syncID == syncID }
    }
}

/// 每条会话此刻跟随不上的事实；接上即清掉。
@MainActor
@Observable
final class SyncFailures {
    private(set) var facts: [ConversationKey: FailureFact] = [:]

    func set(_ fact: FailureFact?, for key: ConversationKey) {
        facts[key] = fact
    }
}

/// 回合事件的去处：对话屏建好之前到达的帧没有人接，建好之后递给它的输入区。
private final class WeakScreen: @unchecked Sendable {
    @MainActor weak var screen: ConversationScreenModel?

    @MainActor
    func apply(_ signal: TurnSignal) async {
        await screen?.apply(signal)
    }
}
