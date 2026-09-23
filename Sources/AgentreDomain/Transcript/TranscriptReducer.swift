import Foundation

/// 帧 → 消息。落点与宿主 agentre-ui 的 frames.ts（reduceFrames）一致：
/// 用户消息各自一条；一轮的正文、思考、工具与卡片进同一条助手消息；决议回填原卡而不新起一条。
public enum TranscriptReducer {
    /// - Parameter initiallyRunning: 还没见过轮次边界时的运行态（取自会话清单的生命周期）。
    public static func reduce(_ entries: [TimelineEntry], initiallyRunning: Bool = false) -> TranscriptDocument {
        var state = State()
        state.document.running = initiallyRunning
        for entry in entries {
            state.apply(entry)
        }
        return state.document
    }

    private struct State {
        var document = TranscriptDocument()
        /// 还能继续吸收块的那条助手消息。
        var open: Int?
        /// 这一轮的那条助手消息：终态帧带来的耗时与错误落在它身上。
        var turn: Int?

        mutating func apply(_ entry: TimelineEntry) {
            if entry.preview {
                applyPreview(entry.event)
                return
            }
            switch entry.event {
            case .userMessage(let text):
                pushUser(text, id: entry.anchor)
            case .steerConsumed(let texts):
                for (index, text) in texts.enumerated() where !text.isEmpty {
                    pushUser(text, id: "\(entry.anchor).\(index)")
                }
            case .textDelta(let text):
                appendText(text, thinking: false, anchor: entry.anchor)
            case .thinkingDelta(let text):
                appendText(text, thinking: true, anchor: entry.anchor)
            case .toolCall(let use):
                append(.toolUse(use), anchor: entry.anchor)
            case .toolResult(let result):
                append(.toolResult(result), anchor: entry.anchor)
            case .permissionRequest(let request):
                append(.permission(request), anchor: entry.anchor)
            case .permissionResolved(let requestID, let allowed, let alwaysAllow):
                mutateLastBlock { block in
                    guard case .permission(var request) = block, request.requestID == requestID else { return false }
                    request.resolved = true
                    request.allowed = allowed
                    request.alwaysAllow = alwaysAllow
                    block = .permission(request)
                    return true
                }
            case .questionRequest(let request):
                append(.question(request), anchor: entry.anchor)
            case .questionResolved(let requestID):
                mutateLastBlock { block in
                    guard case .question(var request) = block, request.requestID == requestID else { return false }
                    request.answered = true
                    block = .question(request)
                    return true
                }
            case .subagent(let update):
                applySubagent(update)
            case .usage(let total, let window):
                let index = openAssistant(anchor: entry.anchor)
                if total > 0 { document.messages[index].totalInputTokens = total }
                if window > 0 { document.contextWindow = window }
            case .contextWindow(let window):
                if window > 0 { document.contextWindow = window }
            case .turnStarted:
                document.running = true
            case .turnDone(let done):
                if let turn {
                    if done.durationMs > 0 { document.messages[turn].durationMs = done.durationMs }
                    if !done.stopError.isEmpty, document.messages[turn].errorText?.isEmpty ?? true { document.messages[turn].errorText = done.stopError }
                }
                if done.contextWindow > 0 { document.contextWindow = done.contextWindow }
                cancelRunningForegroundSubagents()
                document.running = false
                open = nil
            case .error(let message):
                let index = open ?? turn ?? openAssistant(anchor: entry.anchor)
                document.messages[index].errorText = message
                open = nil
            case .ignored:
                break
            }
        }

        mutating func applyPreview(_ event: TranscriptEvent) {
            switch event {
            case .textDelta(let text): document.liveText += text
            case .thinkingDelta(let text): document.liveThinking += text
            default: break
            }
        }

        mutating func pushUser(_ text: String, id: String) {
            document.messages.append(TranscriptMessage(id: id, role: .user, text: text))
            open = nil
            turn = nil
        }

        mutating func openAssistant(anchor: String) -> Int {
            if let open { return open }
            document.messages.append(TranscriptMessage(id: anchor, role: .assistant))
            let index = document.messages.count - 1
            open = index
            turn = index
            return index
        }

        mutating func append(_ block: TranscriptBlock, anchor: String) {
            let index = openAssistant(anchor: anchor)
            document.messages[index].blocks.append(block)
        }

        /// 同类型且紧邻就并进去，否则另起一块。
        mutating func appendText(_ text: String, thinking: Bool, anchor: String) {
            let index = openAssistant(anchor: anchor)
            switch (document.messages[index].blocks.last, thinking) {
            case (.text(let previous)?, false):
                document.messages[index].blocks[document.messages[index].blocks.count - 1] = .text(previous + text)
            case (.thinking(let previous)?, true):
                document.messages[index].blocks[document.messages[index].blocks.count - 1] = .thinking(previous + text)
            default:
                document.messages[index].blocks.append(thinking ? .thinking(text) : .text(text))
            }
        }

        /// 从后往前找第一块让 `body` 认领的块并改写它。
        mutating func mutateLastBlock(_ body: (inout TranscriptBlock) -> Bool) {
            for messageIndex in document.messages.indices.reversed() {
                for blockIndex in document.messages[messageIndex].blocks.indices.reversed() {
                    if body(&document.messages[messageIndex].blocks[blockIndex]) { return }
                }
            }
        }

        /// 一轮收尾时把仍挂在 waiting / running 的前台派遣翻成 canceled（宿主 frames.ts 的
        /// cancelRunningForegroundSubagents）。后台任务本就可以活过发起它的那一轮，不翻。
        mutating func cancelRunningForegroundSubagents() {
            for messageIndex in document.messages.indices {
                for blockIndex in document.messages[messageIndex].blocks.indices {
                    guard case .toolUse(var use) = document.messages[messageIndex].blocks[blockIndex],
                          var state = use.subagent, state.status == "running" || state.status == "waiting",
                          !Self.isBackground(use, kind: state.kind) else { continue }
                    state.status = "canceled"
                    use.subagent = state
                    document.messages[messageIndex].blocks[blockIndex] = .toolUse(use)
                }
            }
        }

        /// 这次派遣是不是后台的：Agent（local_agent）默认后台，只有显式 run_in_background=false 才是前台；
        /// Bash（local_bash）默认前台，只有显式 run_in_background=true 才是后台；其它 kind（含空）一律前台。
        static func isBackground(_ use: ToolUse, kind: String) -> Bool {
            let explicit: Bool? = if case .bool(let value)? = use.input?["run_in_background"] { value } else { nil }
            switch kind {
            case "local_agent": return explicit != false
            case "local_bash": return explicit == true
            default: return false
            }
        }

        /// 先按任务 id 找（恢复重开的 Subagent 沿用同一个任务），再按派生它的调用找。与宿主 frames.ts 同：
        /// 前台 Bash（local_bash 且没有 run_in_background=true）在开始时不挂状态；进度与结束只更新已经挂着
        /// 状态的调用，不反过来给它补挂。
        mutating func applySubagent(_ update: SubagentUpdate) {
            let info = update.info
            func claim(_ block: inout TranscriptBlock, byTask: Bool) -> Bool {
                guard case .toolUse(var use) = block else { return false }
                let matches = byTask ? (!info.taskID.isEmpty && use.subagent?.taskID == info.taskID) : use.id == update.toolCallID
                guard matches else { return false }
                if !byTask {
                    switch update.phase {
                    case .started:
                        if info.kind == "local_bash", use.input?["run_in_background"] != .bool(true) { return true }
                    case .progress, .done:
                        if use.subagent == nil { return true }
                    }
                }
                var state = use.subagent ?? SubagentState()
                if !info.taskID.isEmpty { state.taskID = info.taskID }
                if !info.kind.isEmpty { state.kind = info.kind }
                if !info.subagentType.isEmpty { state.subagentType = info.subagentType }
                if !info.taskDescription.isEmpty { state.taskDescription = info.taskDescription }
                if info.durationMs > 0 { state.durationMs = info.durationMs }
                if info.toolUses > 0 { state.toolUses = info.toolUses }
                switch update.phase {
                case .started: state.status = info.status.isEmpty ? "running" : info.status
                case .progress: if !info.status.isEmpty { state.status = info.status }
                case .done: state.status = info.status.isEmpty ? "completed" : info.status
                }
                use.subagent = state
                block = .toolUse(use)
                return true
            }
            var claimed = false
            if !info.taskID.isEmpty {
                mutateLastBlock { block in
                    let hit = claim(&block, byTask: true)
                    claimed = claimed || hit
                    return hit
                }
            }
            if !claimed {
                mutateLastBlock { claim(&$0, byTask: false) }
            }
        }
    }
}
