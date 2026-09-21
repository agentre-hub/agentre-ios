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

    private let relay: any ComposerRelay
    private let settingsSource: any ComposerSettingsSource
    private let mentionSource: any ComposerMentionSource
    private let store: any ConversationStore
    private let mintID: @MainActor () -> String

    /// 开新一轮的调用在飞：连点不重复开。
    private var isStartingTurn = false
    /// 停止本轮的调用在飞：连点不重复发。
    private var isStopping = false
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
        mentionSource: any ComposerMentionSource, store: any ConversationStore,
        mintID: @escaping @MainActor () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.conversation = conversation
        self.relay = relay
        self.settingsSource = settingsSource
        self.mentionSource = mentionSource
        self.store = store
        self.mintID = mintID
    }

    private var key: ConversationKey { conversation.key }
    private var peer: String { conversation.peerFingerprint }

    /// 输入框从不因一轮在跑而禁用：那时发出的话进入队列。只有开新一轮的调用在飞时不能再发。
    public var canSend: Bool {
        !isStartingTurn && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 只在一轮真的在跑时可停；闲着的时候没有什么可停。
    public var canStop: Bool { isTurnRunning && !isStopping }

    public func load() async {
        settings = try? await settingsSource.settings(for: conversation)
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
            isStartingTurn = true
            defer { isStartingTurn = false }
            // 不认 /compact 的 CLI 上把这一句转成压缩调用，否则模型会一本正经地回答「/compact」。
            let compact = trimmed == "/compact" && !SlashCommands.isNativeCompact(backendType: conversation.backendType)
            do {
                try await relay.run(key, peerFingerprint: peer, text: body, compact: compact)
            } catch {
                restore(draft)
            }
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
    }

    /// 一轮收场。正常收场时问执行端插话信箱里还剩什么，取回的几条空一行合并成下一轮（与桌面端
    /// chat_svc 的轮末接续、控制台 useSteerAutoContinue 同一口径）；出错与中断不问也不接续。
    /// 没被取走、也取不回来的那几条挪进「未发送」，等用户处置。
    public func turnEnded(normally: Bool) async {
        isTurnRunning = false
        guard normally else {
            queue.endTurn()
            return
        }
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
        do {
            try await relay.run(key, peerFingerprint: peer, text: next, compact: false)
        } catch {
            restore((text: ComposerMentions.displayText(next), mentions: []))
        }
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
        let restored = queue.dropped.map { ComposerMentions.displayText($0.text) }.joined(separator: "\n\n")
        queue.clearDropped()
        guard !restored.isEmpty else { return }
        text = text.isEmpty ? restored : "\(text)\n\n\(restored)"
        cursor = text.utf16.count
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
    private func restore(_ draft: (text: String, mentions: [MentionRef])) {
        failure = .send
        text = text.isEmpty ? draft.text : "\(draft.text)\n\n\(text)"
        cursor = text.utf16.count
        pickedMentions = draft.mentions + pickedMentions
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
            let commands = SlashCommands.available(backendType: conversation.backendType, skills: skills, describe: ComposerCopy.describe)
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
            ) else { return }
            self.skills = skills
            refreshCandidates()
        }
    }

    private func requestMentions() {
        guard !mentionsRequested else { return }
        mentionsRequested = true
        Task {
            guard let sources = try? await mentionSource.mentionSources() else { return }
            mentionSources = sources
            refreshCandidates()
        }
    }

    // MARK: 面板三项

    public func setPermissionMode(_ mode: String) async {
        guard let settings, settings.permissionMode != mode else { return }
        await change({ try await self.relay.setPermissionMode(self.key, peerFingerprint: self.peer, mode: mode) }) { $0.permissionMode = mode }
    }

    public func setModel(_ choice: ComposerModelChoice) async {
        guard let settings, settings.model != choice else { return }
        await change({ try await self.relay.setModelTarget(self.key, peerFingerprint: self.peer, providerKey: choice.providerKey, modelKey: choice.modelKey) }) {
            $0.model = choice
        }
    }

    /// 空串 = 改回跟随后端配置。no-op 判据是会话行上的值，不是有效档位：会话行为空而后端配的
    /// 是 high 时，显式选 high 是一次真实写入。
    public func setReasoningEffort(_ effort: String) async {
        guard let settings, settings.reasoningEffort != effort else { return }
        await change({ try await self.relay.setReasoningEffort(self.key, peerFingerprint: self.peer, effort: effort) }) { $0.reasoningEffort = effort }
    }

    /// 写成功才改面板上的值：没改成时面板照旧标注机器上真实的那一档。
    private func change(_ write: () async throws -> Void, apply: (inout ComposerSettings) -> Void) async {
        failure = nil
        do {
            try await write()
            if var current = settings {
                apply(&current)
                settings = current
            }
        } catch {
            failure = .change
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
