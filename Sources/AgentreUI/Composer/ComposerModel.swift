import AgentreDomain
import Foundation
import Observation

/// 对话的输入区：发送与排队、轮末接续、斜杠命令与提及的就地候选、面板三项的切换与删除会话。
///
/// 轮次的起止与 steer_consumed 由宿主从转录事件里递进来（`turnStarted` / `turnEnded` /
/// `steersConsumed`）：输入区自己不读帧。
@MainActor
@Observable
public final class ComposerModel {
    public enum Failure: Equatable {
        /// 这条没发出去（字已还回输入框）。
        case send
        /// 面板上的切换没生效。
        case change
        /// 会话没删掉。
        case delete
    }

    /// 输入框上方的一条就地候选。
    public struct Candidate: Identifiable, Equatable {
        public enum Kind: Equatable {
            case slash(SlashCommand)
            case mention(MentionCandidate)
        }

        public let kind: Kind

        public var id: String {
            switch kind {
            case .slash(let command): "slash:\(command.label)"
            case .mention(let mention): "mention:\(mention.ref)"
            }
        }

        public var title: String {
            switch kind {
            case .slash(let command): command.label
            case .mention(let mention): mention.label
            }
        }
    }

    public let conversation: SavedConversation
    public var text = ""
    /// 光标位置（UTF-16 偏移，与 UITextView 的 selectedRange 同一口径）。
    public private(set) var cursor = 0
    public private(set) var isTurnRunning = false
    public private(set) var queue = SteerQueue()
    public private(set) var settings: ComposerSettings?
    public private(set) var candidates: [Candidate] = []
    public private(set) var failure: Failure?
    /// 候选说明所用的语言：输入区视图按它所在环境的 `\.locale`（「我」里选的语言）递进来；一变就按新语言重排候选。
    @ObservationIgnored public var locale: Locale = .autoupdatingCurrent {
        didSet { if locale != oldValue { refreshCandidates() } }
    }

    private let relay: any ComposerRelay
    private let settingsSource: any ComposerSettingsSource
    private let mentionSource: any ComposerMentionSource
    private let store: any ConversationSettingsRecording
    private let mintID: @MainActor () -> String

    /// 开新一轮的调用在飞：连点不重复开。
    private var isStartingTurn = false
    /// 停止本轮的调用在飞：连点不重复发。
    private var isStopping = false
    /// 用户这次亲手选过权限档位：此后执行端报来的档不再顶掉它（控制台 `permissionMode || sessionRuntime.permissionMode`）。
    private var permissionModeChosen = false
    /// 开新一轮的调用在飞时切过档（只改了本机）：值是切之前亲手选过没有，没改成时连它一起退回。
    private var chosenBeforeSwitchWhileStarting: Bool?
    /// 被接受后的补发在飞（连同它回来后的再补）：此时切档只改本机，由补发回来后按此刻的当前档再补一次。
    /// 计数而非开关：补发在飞时这一轮按清单收场、接续那一轮的补发叠在它上面。
    private var supplementsInFlight = 0
    /// 上一次补发下发之后又只改了本机的档：补发回来后按此刻的当前档再补一次。
    private var switchedLocallySinceSupplement = false
    /// 补发在飞时、这一轮已在跑时切过档：值是切之前亲手选过没有。那一次再补就是一轮在跑时切档，没改成时连它一起退回。
    private var chosenBeforeSwitchWhileSupplementing: Bool?
    /// 执行端最近一次确实收下的档（补发与再补、一轮在跑时的切档、落定那一处补上的那一次）与它的下发次序：再补没成时
    /// 面板退回它。执行端按到达次序生效，应答却可能先后颠倒——后发的已收下时，先发的那一次应答晚到不作数。
    private var machineMode: (order: Int, mode: String)?
    private var permissionWrites = 0
    /// 本地库里这条会话最近一次读到的那一行：跟随重新接上时按机器清单刷新，别的端改过的模型与思考档位由此看得见。
    /// 本机切成了模型或思考档位时，那一项照记进库里那一行、这里一并记下：此后库里那一项再变才是别的端改的——
    /// 包括改回本机切之前那一档；清单刷新回来的本机更早那一次选择也不能盖掉本机后来的选择。
    private var savedRow: SavedConversation
    /// 这一轮是按机器的会话状态收掉的（收场帧没递到）；此后、下一轮开起来之前再到的收场帧就是它迟到的那一帧。
    private var endedByReconcile = false
    private var skills: [ComposerSkillSource] = []
    private var skillsRequested = false
    private var mentionSources = ComposerMentionSources()
    private var mentionsRequested = false
    /// 这一段草稿里选过的提及，发送时换成 XML。
    private var pickedMentions: [MentionRef] = []
    /// 此刻在光标处生效的触发。
    private var trigger: Trigger?

    private enum Trigger: Equatable {
        case slash(SlashTriggerHit)
        case mention(MentionTriggerHit)
    }

    public init(
        conversation: SavedConversation, relay: any ComposerRelay, settingsSource: any ComposerSettingsSource,
        mentionSource: any ComposerMentionSource, store: any ConversationSettingsRecording,
        mintID: @escaping @MainActor () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.conversation = conversation
        self.savedRow = conversation
        self.relay = relay
        self.settingsSource = settingsSource
        self.mentionSource = mentionSource
        self.store = store
        self.mintID = mintID
    }

    private var key: ConversationKey { conversation.key }
    private var peer: String { conversation.peerFingerprint }
    /// 本机此刻生效的权限档位，随每一轮 runtime.run 带过去；面板还没载入时为空（执行端按默认档跑）。
    private var permissionMode: String { settings?.permissionMode ?? "" }

    /// 随每一轮 runtime.run 带过去的设定：执行端只认 run 上带的模型目标与思考档位，面板上切的只写进会话行供显示。
    /// 模型目标与桌面端 remoteKeysOnlyEffective 同一取法：钉了供应商就带会话的两枚键（模型键空 = 供应商默认模型），
    /// 没钉两格都空、跟随 Agent 绑定。面板上没有可标注的模型（没钉、或只钉了供应商）或面板还没载入时取会话行上的。
    /// 取之前先 `followSavedRow()`。
    private var runSettings: ComposerRunSettings {
        let providerKey = settings?.model?.providerKey ?? savedRow.providerKey
        let modelKey = settings?.model?.modelKey ?? savedRow.modelKey
        return ComposerRunSettings(
            permissionMode: permissionMode,
            providerKey: providerKey,
            modelKey: providerKey.isEmpty ? "" : modelKey,
            reasoningEffort: settings?.reasoningEffort ?? savedRow.reasoningEffort
        )
    }

    /// 开一轮之前重读本地库里这一行：模型目标或思考档位与上次读到的不同，就是别的端改过（或本机切的已随清单刷新回来），
    /// 这一轮跟随它、面板一并标注；没变就留着本机此刻的，包括亲手切过、清单还没刷新到的那一次。
    /// 屏模型在登录期间一直留着，打开时那一份会话行不能一直当真，否则每一轮都拿旧值盖掉别的端后来的选择。
    private func followSavedRow() async {
        guard let row = try? await store.conversation(key) else { return }
        let seen = savedRow
        savedRow = row
        guard var current = settings else { return }
        if row.providerKey != seen.providerKey || row.modelKey != seen.modelKey {
            current.model = ComposerSettings.savedModel(of: row, in: current.models)
        }
        if row.reasoningEffort != seen.reasoningEffort { current.reasoningEffort = row.reasoningEffort }
        settings = current
    }

    /// 输入框从不因一轮在跑而禁用：那时发出的话进入队列。只有开新一轮的调用在飞时不能再发。
    public var canSend: Bool {
        !isStartingTurn && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 只在一轮真的在跑时可停；闲着的时候没有什么可停。
    public var canStop: Bool { isTurnRunning && !isStopping }

    /// 面板按库里此刻那一行标注：屏模型建好之后那一行可能已按清单刷新过。
    public func load() async {
        if let row = try? await store.conversation(key) { savedRow = row }
        settings = try? await settingsSource.settings(for: savedRow)
    }

    // MARK: 发送与排队

    /// 空闲时开新一轮；一轮在跑时这句话排进队列（插话），输入框照常可用。
    public func send() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let body = ComposerMentions.serialize(trimmed, mentions: pickedMentions)
        let draft = (text: text, mentions: pickedMentions)
        failure = nil
        clearDraft()
        if isTurnRunning {
            let localID = mintID()
            queue.enqueue(id: localID, text: body)
            do {
                queue.adopt(localID: localID, handle: try await relay.steer(key, peerFingerprint: peer, queuedID: localID, text: body))
            } catch {
                queue.drop([localID])
                restore(draft)
            }
        } else {
            // 不认 /compact 的 CLI 上把这一句转成压缩调用，否则模型会一本正经地回答「/compact」。
            let compact = trimmed == "/compact" && SlashCommands.isHostCompact(backendType: conversation.backendType)
            isStartingTurn = true
            chosenBeforeSwitchWhileStarting = nil
            await followSavedRow()
            let carried = runSettings
            let receipt: ComposerRunReceipt
            do {
                receipt = try await relay.run(key, peerFingerprint: peer, text: body, compact: compact, settings: carried)
            } catch {
                isStartingTurn = false
                restore(draft)
                return
            }
            isStartingTurn = false
            await settle(receipt, carried: carried.permissionMode)
        }
    }

    /// 这一轮被机器受理之后。应答到了：补发一次当前档——agentred 复用上一轮还在池里的执行进程时不应用
    /// runtime.run 带的档（claudecode/runtime.go:620-626，复用判据 launchIdentity 不含档位），此刻这一轮已登记、
    /// runtime.setPermissionMode 落得到活着的 CLI 上（:342-357）。不论这次切没切过档都补：App 重启、别的端改过档
    /// 之后池里的进程一样是旧档。补发没成（这一轮已收场、执行端不认权限模式……）不提示、不改变这次发送的结果。
    /// 应答丢了、问机器才确认受理的那一轮不补发，按机器报的生命周期落定；调用在飞时用户切过档、这一轮
    /// 还在跑，那一次就是一轮在跑时切档：此刻让它即刻生效，没改成如实呈现、面板退回这一轮带出去的那一档。
    private func settle(_ receipt: ComposerRunReceipt, carried: String) async {
        let chosenBefore = chosenBeforeSwitchWhileStarting
        chosenBeforeSwitchWhileStarting = nil
        switch receipt {
        case .acknowledged:
            // 补发在飞时的切档只改本机（轮末接续那一轮的开轮帧要等这里落定之后才递得进来；发送那一轮的开轮帧
            // 到了也不另发——另发的那一次应答在路上时，这里再补读到的还是它之前的档，后到执行端反把它盖掉）：
            // 补发回来后按此刻的当前档再补一次，否则这一轮一直按补发带的旧档跑。每多补一次都要用户又切过一次。
            // 补发本身没成不提示；为一轮在跑时的切档再补的那一次没成，如实呈现、面板退回执行端最近确实收下的那一档
            // （补发在飞时接续的那一轮可能已补上别的档）。
            supplementsInFlight += 1
            defer { supplementsInFlight -= 1 }
            var delivered = false
            repeat {
                switchedLocallySinceSupplement = false
                let chosenBeforeRunningSwitch = chosenBeforeSwitchWhileSupplementing
                chosenBeforeSwitchWhileSupplementing = nil
                let mode = permissionMode
                guard !mode.isEmpty else { return }
                do {
                    try await writePermissionMode(mode)
                    delivered = true
                } catch {
                    guard let chosenBeforeRunningSwitch, delivered, let machineMode = machineMode?.mode else { return }
                    failure = .change
                    // 这次再补在飞时、这一轮在跑时又切的那一档同样只改了本机、没到执行端，一并退回；
                    // 那之后是在两轮之间切的（这一轮已收场），留给下一轮带过去。
                    guard settings?.permissionMode == mode || chosenBeforeSwitchWhileSupplementing != nil else { return }
                    chosenBeforeSwitchWhileSupplementing = nil
                    settings?.permissionMode = machineMode
                    permissionModeChosen = chosenBeforeRunningSwitch
                    return
                }
            } while switchedLocallySinceSupplement
        case .confirmed(let lifecycle):
            await settleConfirmedTurn(lifecycle: lifecycle)
            guard lifecycle == SavedConversation.Lifecycle.running, let chosenBefore, permissionMode != carried else { return }
            let mode = permissionMode
            do {
                try await writePermissionMode(mode)
            } catch {
                failure = .change
                guard settings?.permissionMode == mode else { return }
                settings?.permissionMode = carried
                permissionModeChosen = chosenBefore
            }
        }
    }

    /// 应答没到、回头问机器才知道它受理了的那一轮：开轮帧与收场帧都可能随那条连接丢了，
    /// 按机器此刻报的生命周期落定——还在跑就是运行中（可停），已不在跑就按那一次收场处置。
    private func settleConfirmedTurn(lifecycle: String?) async {
        guard let lifecycle else { return }
        if lifecycle == SavedConversation.Lifecycle.running {
            if !isTurnRunning { turnStarted() }
        } else {
            await reconcile(lifecycle: lifecycle)
        }
    }

    /// 停止本轮（runtimeAbort）。停没停下来由这一轮的收场帧说话；停不下来也不另开一条错误面
    /// ——实时流照常继续，状态自己说话（与控制台 SessionDetailHeader 的停止同一口径）。
    public func stop() async {
        guard canStop else { return }
        isStopping = true
        defer { isStopping = false }
        try? await relay.abort(key, peerFingerprint: peer)
    }

    public func turnStarted() {
        isTurnRunning = true
        endedByReconcile = false
    }

    /// 一轮收场。正常收场时问执行端插话信箱里还剩什么，取回的几条空一行合并成下一轮（与桌面端
    /// chat_svc 的轮末接续、控制台 useSteerAutoContinue 同一口径）；出错与中断不问也不接续。
    /// 没被取走、也取不回来的那几条挪进「未发送」，等用户处置。
    public func turnEnded(normally: Bool) async {
        if endedByReconcile {
            endedByReconcile = false
            return
        }
        await settleTurn(normally: normally)
    }

    private func settleTurn(normally: Bool) async {
        isTurnRunning = false
        guard normally else {
            queue.endTurn()
            return
        }
        // 问信箱与接续那一轮在路上时，这就是一次开新一轮的调用：此时点发送不能再另开一轮。
        isStartingTurn = true
        chosenBeforeSwitchWhileStarting = nil
        defer { isStartingTurn = false }
        let drained: [ComposerConsumedSteer]?
        do {
            drained = try await relay.drainPending(key, peerFingerprint: peer)
        } catch {
            queue.endTurn()
            return
        }
        guard let drained else {
            queue.endTurn()
            return
        }
        queue.consume(drained)
        queue.endTurn()
        let next = drained.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !next.isEmpty else { return }
        await followSavedRow()
        let carried = runSettings
        let receipt: ComposerRunReceipt
        do {
            receipt = try await relay.run(key, peerFingerprint: peer, text: next, compact: false, settings: carried)
        } catch {
            restore(ComposerMentions.draft(fromBody: next))
            return
        }
        // 与发送同一处落定：被接受就补发当前档；应答丢了时接续那一轮的开轮帧可能已递到、收场帧随连接丢了，
        // 只有机器报的生命周期说得出来。
        isStartingTurn = false
        await settle(receipt, carried: carried.permissionMode)
    }

    /// 重新接上承载机后，机器此刻报的会话生命周期。以为在跑、机器却说不在跑了：这一轮在看不到的时候
    /// （后台、断线）收了场，收场帧不带号、补拉不回来，只有清单说得出来——就地按那一次收场处置，与收场帧
    /// 同一口径（正常收场问信箱并接续，出错与中断不问）。只认「在跑 → 不在跑」这一个方向；开新一轮的
    /// 调用在飞时的快照可能早于这一轮，不作数。
    public func reconcile(lifecycle: String) async {
        guard isTurnRunning, !isStartingTurn, lifecycle != SavedConversation.Lifecycle.running else { return }
        endedByReconcile = true
        await settleTurn(normally: lifecycle == SavedConversation.Lifecycle.idle)
    }

    public func steersConsumed(_ consumed: [ComposerConsumedSteer]) {
        queue.consume(consumed)
    }

    /// 撤回一条：对端确认撤掉即移除；被拒或问不通时留在原位、转成撤不掉。
    public func cancelQueued(_ id: String) async {
        guard queue.items.contains(where: { $0.id == id && $0.cancellable }) else { return }
        do {
            let removed = try await relay.cancelSteer(key, peerFingerprint: peer, queuedID: id)
            if removed.contains(id) {
                queue.drop(removed)
            } else {
                queue.markNotCancellable(id)
            }
        } catch {
            queue.markNotCancellable(id)
        }
    }

    /// 轮末没发出去的那几条回到输入框（接在已有草稿之后）。
    public func restoreDropped() {
        let restored = ComposerMentions.draft(fromBody: queue.dropped.map(\.text).joined(separator: "\n\n"))
        queue.clearDropped()
        guard !restored.text.isEmpty else { return }
        pickedMentions += restored.mentions
        let merged = text.isEmpty ? restored.text : "\(text)\n\n\(restored.text)"
        edit(text: merged, cursor: merged.utf16.count)
    }

    public func discardDropped() {
        queue.clearDropped()
    }

    private func clearDraft() {
        text = ""
        cursor = 0
        pickedMentions = []
        trigger = nil
        candidates = []
    }

    /// 没发出去的草稿还回输入框；用户在此期间又打了字时接在它前面，不覆盖。
    /// 正文变了，就地候选按新的正文与光标重算（选中时按它替换，不能照着改写之前的位置）。
    private func restore(_ draft: (text: String, mentions: [MentionRef])) {
        failure = .send
        pickedMentions = draft.mentions + pickedMentions
        let merged = text.isEmpty ? draft.text : "\(draft.text)\n\n\(text)"
        edit(text: merged, cursor: merged.utf16.count)
    }

    // MARK: 就地触发

    /// 输入框的内容或光标变了：按光标前的文本判定斜杠命令与提及，就地给出候选。
    public func edit(text: String, cursor: Int) {
        self.text = text
        self.cursor = min(max(0, cursor), text.utf16.count)
        let before = (text as NSString).substring(to: self.cursor)
        let triggers: Set<Character> = SlashCommands.skillPrefix(backendType: conversation.backendType) == "$" ? ["/", "$"] : ["/"]
        if let hit = ComposerTrigger.detectSlash(before, triggers: triggers) {
            trigger = .slash(hit)
            requestSkills()
        } else if let hit = ComposerTrigger.detectMention(before) {
            trigger = .mention(hit)
            requestMentions()
        } else {
            trigger = nil
        }
        refreshCandidates()
    }

    /// 选中一条候选：替换光标前的触发段，后接一个空格。
    public func select(_ candidate: Candidate) {
        guard let trigger else { return }
        let start: Int
        let insertion: String
        switch (trigger, candidate.kind) {
        case (.slash(let hit), .slash(let command)):
            start = hit.startOffset
            insertion = command.insertion.hasSuffix(" ") ? command.insertion : "\(command.insertion) "
        case (.mention(let hit), .mention(let mention)):
            start = hit.startOffset
            insertion = "@\(mention.label) "
            pickedMentions.append(mention.ref)
        default:
            return
        }
        let before = Array((text as NSString).substring(to: cursor))
        let after = (text as NSString).substring(from: cursor)
        let head = String(before[..<start]) + insertion
        text = head + after
        cursor = head.utf16.count
        self.trigger = nil
        candidates = []
    }

    private func refreshCandidates() {
        switch trigger {
        case .slash(let hit):
            let commands = SlashCommands.available(backendType: conversation.backendType, skills: skills, describe: { [locale] in ComposerCopy.describe($0, locale: locale) })
            candidates = SlashCommands.filter(commands, query: hit.query, trigger: hit.trigger).map { Candidate(kind: .slash($0)) }
        case .mention(let hit):
            candidates = ComposerMentions.rank(mentionSources, query: hit.query).map { Candidate(kind: .mention($0)) }
        case nil:
            candidates = []
        }
    }

    /// Skill 目录向承载这条会话的机器要（适配器按会话解析承载机），按会话的工作目录解析项目级 Skill；每条会话只要一次。
    /// 要不到就只列内置命令：没有补全比挡住用户正在打的那句话正确。
    private func requestSkills() {
        guard !skillsRequested, SlashCommands.skillPrefix(backendType: conversation.backendType) != nil else { return }
        skillsRequested = true
        Task {
            guard let skills = try? await relay.skillCommands(
                key, agentSyncID: conversation.agentSyncID,
                backendType: conversation.backendType, cwd: conversation.cwd
            ) else {
                // 一时要不到（离线、机器没答）：下一次键入触发再问。
                skillsRequested = false
                return
            }
            self.skills = skills
            refreshCandidates()
        }
    }

    private func requestMentions() {
        guard !mentionsRequested else { return }
        mentionsRequested = true
        Task {
            guard let sources = try? await mentionSource.mentionSources() else {
                mentionsRequested = false
                return
            }
            mentionSources = sources
            refreshCandidates()
        }
    }

    // MARK: 面板三项

    /// 权限档位随每一轮发送带过去（与控制台 useSessionSend、桌面端 usePermissionMode 同一口径）：
    /// 两轮之间只改本机记下的当前档，下一轮随 runtime.run 与它被接受后的补发生效——此时执行端已把会话收掉，
    /// 去问它只会得到「没有进行中的一轮」。一轮正在跑时再额外让它即刻生效，那一次没改成才如实呈现。
    /// 开新一轮的调用在飞时同两轮之间：被接受后的补发读的就是此刻的当前档，另发一次反倒会被在它之后到的补发盖掉；
    /// 应答丢了没有补发时，由落定那一处补上。补发在飞时同样只改本机，由补发回来后再补一次；切的时候这一轮已在跑，
    /// 那一次再补就是一轮在跑时切档，没改成如实呈现，否则同补发、不提示。
    public func setPermissionMode(_ mode: String) async {
        guard var settings, settings.permissionMode != mode else { return }
        guard isTurnRunning, !isStartingTurn, supplementsInFlight == 0 else {
            if isStartingTurn, chosenBeforeSwitchWhileStarting == nil { chosenBeforeSwitchWhileStarting = permissionModeChosen }
            if isTurnRunning, !isStartingTurn, chosenBeforeSwitchWhileSupplementing == nil {
                chosenBeforeSwitchWhileSupplementing = permissionModeChosen
            }
            switchedLocallySinceSupplement = true
            failure = nil
            permissionModeChosen = true
            settings.permissionMode = mode
            self.settings = settings
            return
        }
        if await change({ try await self.writePermissionMode(mode) }, apply: { $0.permissionMode = mode }) { permissionModeChosen = true }
    }

    private func writePermissionMode(_ mode: String) async throws {
        permissionWrites += 1
        let order = permissionWrites
        try await relay.setPermissionMode(key, peerFingerprint: peer, mode: mode)
        if order > machineMode?.order ?? 0 { machineMode = (order, mode) }
    }

    /// 执行端在转录里报了它此刻的档位（例如退出计划模式后）。起手档位的取法与控制台同：用户这次选的 →
    /// 执行端报过的当前档——所以用户这次没选过时，面板与下一轮 runtime.run 跟着它走，不把执行端顶回旧档；
    /// 报来的档不在这台机器的可选范围里时不认（与起手档同一口径）。
    public func permissionModeReported(_ mode: String) {
        guard !permissionModeChosen, var settings, !mode.isEmpty, settings.permissionMode != mode else { return }
        guard settings.permissionModes.isEmpty || settings.permissionModes.contains(mode) else { return }
        settings.permissionMode = mode
        self.settings = settings
    }

    public func setModel(_ choice: ComposerModelChoice) async {
        guard let settings, settings.model != choice else { return }
        let changed = await change({ try await self.relay.setModelTarget(self.key, peerFingerprint: self.peer, providerKey: choice.providerKey, modelKey: choice.modelKey) }) {
            $0.model = choice
        }
        guard changed, (try? await store.recordModelTarget(key, providerKey: choice.providerKey, modelKey: choice.modelKey)) != nil else { return }
        savedRow.providerKey = choice.providerKey
        savedRow.modelKey = choice.modelKey
    }

    /// 空串 = 改回跟随后端配置。no-op 判据是会话行上的值，不是有效档位：会话行为空而后端配的
    /// 是 high 时，显式选 high 是一次真实写入。
    public func setReasoningEffort(_ effort: String) async {
        guard let settings, settings.reasoningEffort != effort else { return }
        let changed = await change({ try await self.relay.setReasoningEffort(self.key, peerFingerprint: self.peer, effort: effort) }) { $0.reasoningEffort = effort }
        guard changed, (try? await store.recordReasoningEffort(key, effort: effort)) != nil else { return }
        savedRow.reasoningEffort = effort
    }

    /// 写成功才改面板上的值：没改成时面板照旧标注机器上真实的那一档。交回写成了没有——不拿 `failure` 判：
    /// 写在飞时别的操作没成，也会把它记上。
    private func change(_ write: () async throws -> Void, apply: (inout ComposerSettings) -> Void) async -> Bool {
        failure = nil
        do {
            try await write()
            if var current = settings {
                apply(&current)
                settings = current
            }
            return true
        } catch {
            failure = .change
            return false
        }
    }

    // MARK: 删除

    /// 在承载机上删除这条会话，再删掉本地这一份。机器上没删成时本地一条不动。
    public func deleteConversation() async -> Bool {
        failure = nil
        do {
            _ = try await relay.deleteSession(key, peerFingerprint: peer)
            try await store.delete(key)
            return true
        } catch {
            failure = .delete
            return false
        }
    }
}
