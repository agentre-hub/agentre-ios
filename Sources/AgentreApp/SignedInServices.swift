import AgentreDomain
import AgentreRelay
import AgentreREST
import AgentreStore
import AgentreUI
import Foundation
import Observation
import SwiftUI

/// 消息标签里的去处。
enum MessagesRoute: Hashable {
    case conversation(ConversationKey)
}

/// 新建对话模态自己的栈里的去处（根屏是 Agent 列表）。
enum NewConversationRoute: Hashable {
    case projects
    case project(String)
    case draft(agent: String, project: String?)
}

/// 机器标签里的去处。
enum MachinesRoute: Hashable {
    case machine(String)
    case conversation(ConversationKey)
}

/// 选中的顶层页、三个导航栈的路径与新建对话模态。
@MainActor
@Observable
final class Router {
    var tab: ShellTab = .messages
    var messages: [MessagesRoute] = []
    var machines: [MachinesRoute] = []
    /// 「我」的二级页须以值入栈（`NavigationLink(value:)`），栈深才看得见、tab 栏才会随之退场。
    var me = NavigationPath()
    /// 新建对话模态的栈；nil 即模态没开，`[]` 是开在 Agent 列表上。
    var newConversation: [NewConversationRoute]? {
        didSet { onNewConversationChange?(newConversation ?? []) }
    }
    /// 新建对话的栈变了：离开栈的草稿随之作废。
    @ObservationIgnored var onNewConversationChange: (([NewConversationRoute]) -> Void)?

    /// tab 栏只在当前顶层页的栈空、且没有模态时出现（决策 23；键盘由外壳自己看）。
    var showsTabBar: Bool {
        guard newConversation == nil else { return false }
        switch tab {
        case .messages: return messages.isEmpty
        case .machines: return machines.isEmpty
        case .me: return me.isEmpty
        }
    }

    /// 草稿的第一条发出去了：模态收起，这条对话在消息页的栈上打开，返回即回到消息列表。
    func open(started key: ConversationKey) {
        newConversation = nil
        tab = .messages
        messages = [.conversation(key)]
    }
}

/// 一条会话打开后的全部状态：转录、这条会话唯一的一份卡片状态、输入区。
@MainActor
final class ConversationScreenModel {
    let conversation: SavedConversation
    let transcript: TranscriptModel
    let cards: ApprovalCardsModel
    let composer: ComposerModel

    init(conversation: SavedConversation, transcript: TranscriptModel, cards: ApprovalCardsModel, composer: ComposerModel) {
        self.conversation = conversation
        self.transcript = transcript
        self.cards = cards
        self.composer = composer
    }

    /// 转录实时帧里的回合事件与执行端报的档位递给输入区。
    func apply(_ signal: TurnSignal) async {
        switch signal {
        case .started: composer.turnStarted()
        case .ended(let normally): await composer.turnEnded(normally: normally)
        case .steersConsumed(let consumed): composer.steersConsumed(consumed)
        case .permissionModeReported(let mode): composer.permissionModeReported(mode)
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
    /// 新建的对话落库：发起端是本机（与机器报的 peer_fingerprint 同一个指纹，也是派单时的来源设备）。
    @ObservationIgnored let startedRecorder: StartedConversationRecorder
    @ObservationIgnored let workspace: WorkspaceClient
    /// 会话头像字形与副标题据此解出所属项目与承载机器名（规格「全局框架」头像字形一条）。
    @ObservationIgnored let identity: WorkspaceIdentityDirectory
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
    @ObservationIgnored private var drafts: [NewConversationRoute: DraftConversationModel] = [:]
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
            // 中继没有 401 可等：令牌过期就先刷新再拨号、再握手（规格「登录」：过期以刷新令牌换新）。
            accessToken: { try await tokens.unexpiredAccessToken() }, sleeper: dependencies.relaySleeper
        )
        // 承载机只认本地库那一行：行已不在（开着的屏上删掉了）就没有通道可走，不拿发起端去顶。
        let carrier: RelayCarrier = { key in
            guard let carrier = try await store.carrier(of: key) else { throw RelayFailure.machineUnreachable }
            return carrier
        }
        self.carrier = carrier
        let source = RelaySourceDevice(
            fingerprint: (try? dependencies.credentials.deviceFingerprint().value) ?? "", name: dependencies.deviceName
        )
        machineSessions = RelayMachineSessions(connection: connection, caller: source.fingerprint)
        transfer = RewindingTransfer(inner: machineSessions, store: store)
        approvals = RelayApprovalAnswering(connection: connection, carrier: carrier)
        let roster = MachineRosterClient(transport: environment.transport, server: server)
        let directory = MachineDirectory(roster: roster)
        composerRelay = RelayComposer(
            connection: connection, source: source, carrier: carrier,
            conversation: { key in try? await store.conversation(key) },
            machineKind: { fingerprint in await directory.kind(of: fingerprint) },
            // Skill 授权是组织数据，设备令牌能读的 REST 面上没有它：按空授权问，机器仍答得出它自己解析的那一半。
            skillGrants: { _, _, _ in [] }
        )
        dispatcher = RelayDispatcher(connection: connection, source: source)
        startedRecorder = StartedConversationRecorder(store: store, origin: source.fingerprint)
        workspace = WorkspaceClient(transport: environment.transport, server: server)
        identity = WorkspaceIdentityDirectory(workspace: workspace, roster: roster)
        mentions = RESTMentionSource(workspace: workspace, machines: directory)
        settings = ComposerSettingsAdapter(
            catalog: EngineCatalogClient(transport: environment.transport, server: server), connection: connection, carrier: carrier,
            store: store
        )
        messages = MessagesModel(store: store, identity: identity)
        machines = MachinesModel(roster: roster)
        newConversation = NewConversationModel(workspace: workspace, store: store)
        let failures = SyncFailures()
        self.failures = failures
        let recovered = RecoveredFollows()
        sync = ConversationSync(
            connection: connection, store: store, sessions: machineSessions,
            onFailure: { key, fact in
                await failures.set(fact, for: key)
                if fact == nil { await recovered.notify(key) }
            },
            onLifecycle: { key, lifecycle in await recovered.reconcile(key, lifecycle: lifecycle) }
        )
        // 跟随重新接上了承载机：那条会话若正开着、实时流已收场，一并接上。回到前台时通道的关闭帧
        // 可能晚于 resume 才读到，这一步兜住那个次序。
        recovered.handler = { [weak self] key in self?.conversations[key]?.transcript.resume() }
        // 接上后机器报的生命周期交给那条会话的转录与输入区：看不到的时候（后台、断线）收场的那一轮，
        // 收场帧不会补拉回来，只有它说得出来。轮末接续是几次往返，不压住跟随落库。
        recovered.lifecycleHandler = { [weak self] key, lifecycle in
            guard let screen = self?.conversations[key] else { return }
            screen.transcript.reconcile(lifecycle: lifecycle)
            let composer = screen.composer
            Task { await composer.reconcile(lifecycle: lifecycle) }
        }
        // 草稿只活在它那一次新建里：发出去换成了对话、或者退出了新建那几屏，再选同一个 Agent 是一张新草稿，
        // 机器覆盖也随之作废（规格「覆盖只对这一次生效」）。
        router.onNewConversationChange = { [weak self] path in
            self?.drafts = self?.drafts.filter { path.contains($0.key) } ?? [:]
        }
    }

    func start() {
        guard syncTask == nil else { return }
        let connection = connection
        let sync = sync
        syncTask = Task {
            await connection.start()
            await sync.run()
        }
        let identity = identity
        Task { await identity.load() }
    }

    /// 回到前台、网络恢复、或用户点了重试：补上没在跟随的会话（连接自己会重拨），
    /// 并让开着的对话屏里已收场的实时流从转录自己的最新帧号重新接上。
    func resume() async {
        for screen in conversations.values { screen.transcript.resume() }
        await sync.resync()
    }

    func stop() async {
        syncTask?.cancel()
        syncTask = nil
        await sync.stop()
        await connection.stop()
    }

    // MARK: 各屏的模型（同一去处只建一次）

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
                inner: RelayTranscript(connection: connection, carrier: carrier),
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
            composer: composer
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

    func draftModel(for route: NewConversationRoute) -> DraftConversationModel? {
        guard case .draft(let agentID, let projectID) = route else { return nil }
        if let cached = drafts[route] { return cached }
        guard let agent = newConversation.agents.first(where: { $0.syncID == agentID }) else { return nil }
        let projects = newConversation.projects
        let model = DraftConversationModel(
            agent: agent, project: projectID.flatMap { id in projects.first { $0.syncID == id } }, projects: projects,
            workspace: workspace, dispatcher: dispatcher, recorder: startedRecorder
        )
        // 已经退出栈的去处（退场动画里再求一次值）不留：否则下一次进来拿到的是它。
        if router.newConversation?.contains(route) == true { drafts[route] = model }
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

/// 跟随接上的通知：跟随在建好对话屏的那一套之前就要构造，处理方随后再挂上。
@MainActor
private final class RecoveredFollows: Sendable {
    var handler: ((ConversationKey) -> Void)?
    var lifecycleHandler: ((ConversationKey, String) -> Void)?

    func notify(_ key: ConversationKey) {
        handler?(key)
    }

    func reconcile(_ key: ConversationKey, lifecycle: String) {
        lifecycleHandler?(key, lifecycle)
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
