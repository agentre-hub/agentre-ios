import Foundation

/// 归约后的转录 → 一行一行。一个可点元素一行（组头、步骤、省略行、Subagent），
/// 所以列表能把每一个都当作独立的行来虚拟化，折叠态的步骤一行都不产出。
public enum TranscriptRows {
    /// - Parameter cwd: 会话的工作目录：步骤标签里它之下的路径写成 `./相对路径`。
    public static func build(_ document: TranscriptDocument, disclosure: TranscriptDisclosure = TranscriptDisclosure(), cwd: String? = nil) -> [TranscriptRow] {
        var builder = Builder(disclosure: disclosure, cwd: cwd)
        let lastAssistant = document.messages.lastIndex { $0.role == .assistant }
        for (index, message) in document.messages.enumerated() {
            switch message.role {
            case .user:
                builder.rows.append(TranscriptRow(id: "message:\(message.id):user", content: .user(message.text)))
            case .assistant:
                let isLatest = index == lastAssistant
                builder.appendAssistant(message, document: document, isLatest: isLatest)
            }
        }
        // 最后一条是用户消息而轮次还在跑、预览尾巴却已经来了：没有助手消息可挂，单起一条。
        if lastAssistant == nil || document.messages.last?.role == .user, !document.liveText.isEmpty || !document.liveThinking.isEmpty {
            builder.appendAssistant(TranscriptMessage(id: "live", role: .assistant), document: document, isLatest: true)
        }
        return builder.rows
    }

    private struct Builder {
        let disclosure: TranscriptDisclosure
        let cwd: String?
        var rows: [TranscriptRow] = []

        mutating func appendAssistant(_ message: TranscriptMessage, document: TranscriptDocument, isLatest: Bool) {
            // 预览尾巴只挂在最新的那条助手消息上，且它必须是整段转录的末条。
            let takesLive = isLatest && document.messages.last?.id == message.id || message.id == "live"
            let items = TranscriptItems.build(
                messageID: message.id,
                blocks: message.blocks,
                liveThinking: takesLive ? document.liveThinking : "",
                liveText: takesLive ? document.liveText : ""
            )
            guard !items.isEmpty || message.errorText != nil else { return }
            rows.append(TranscriptRow(id: "message:\(message.id):agent", content: .agentHeader))
            let turnRunning = takesLive && document.running
            for (index, item) in items.enumerated() {
                let isTail = index == items.count - 1
                switch item {
                case .text(let key, let text, let streaming):
                    rows.append(TranscriptRow(id: key, content: .text(text, streaming: streaming)))
                case .thinking(let key, let text, _):
                    rows.append(TranscriptRow(id: key, content: .thinking(text)))
                case .activity(let group):
                    appendBlock(
                        key: group.key, steps: group.steps, summary: group.summary,
                        running: turnRunning && (isTail || group.growing),
                        defaultExpanded: false, durationMs: message.durationMs, depth: 0, pendingOutcome: .running
                    )
                case .subagent(let group):
                    appendSubagent(group, turnRunning: turnRunning)
                case .card(let key, let card):
                    rows.append(TranscriptRow(id: key, content: .card(card)))
                }
            }
            if let errorText = message.errorText {
                rows.append(TranscriptRow(id: "message:\(message.id):error", content: .error(errorText)))
            }
        }

        mutating func appendBlock(
            key: String, steps: [ActivityStep], summary: ActivitySummary, running: Bool,
            defaultExpanded: Bool, durationMs: Int, depth: Int, pendingOutcome: PendingOutcome
        ) {
            guard !steps.isEmpty else { return }
            let layout = ActivityDisclosure.layout(
                stepCount: steps.count, running: running, defaultExpanded: defaultExpanded,
                userExpanded: disclosure.expanded[key], userShowAll: disclosure.showAllSteps.contains(key), durationMs: durationMs
            )
            guard layout.showsHeader else {
                appendStep(steps[0], depth: depth, standalone: true, pendingOutcome: pendingOutcome)
                return
            }
            rows.append(TranscriptRow(id: key, content: .activityHeader(ActivityHeaderRow(
                blockKey: key, summary: summary, running: running, expanded: layout.expanded, durationMs: layout.durationMs, depth: depth
            ))))
            guard layout.expanded else { return }
            if layout.elidedCount > 0 {
                let elided = Array(steps.prefix(layout.elidedCount))
                rows.append(TranscriptRow(id: "\(key):elided", content: .elided(ElidedRow(
                    blockKey: key, count: elided.count,
                    summary: ActivityRules.summarize(elided, unresolvedFailed: pendingOutcome == .failed), depth: depth
                ))))
            }
            for step in steps.dropFirst(layout.elidedCount) {
                appendStep(step, depth: depth, standalone: false, pendingOutcome: pendingOutcome)
            }
        }

        mutating func appendStep(_ step: ActivityStep, depth: Int, standalone: Bool, pendingOutcome: PendingOutcome) {
            let expanded = disclosure.expanded[step.id] ?? false
            let row = StepRow(
                key: step.id, step: step, facts: step.facts(pendingOutcome: pendingOutcome), label: step.label(cwd: cwd),
                weight: step.weight, category: step.toolUse?.category, depth: depth, standalone: standalone, expanded: expanded
            )
            rows.append(TranscriptRow(id: step.id, content: .step(row)))
            if expanded {
                rows.append(TranscriptRow(id: "\(step.id):detail", content: .stepDetail(row)))
            }
        }

        /// Subagent：折叠态一行（名称、步数、耗时）；展开后是它自己的活动块。
        mutating func appendSubagent(_ group: SubagentGroup, turnRunning: Bool) {
            let state = group.use.subagent
            let status = state?.status ?? ""
            let running = status.isEmpty ? (group.result == nil && turnRunning) : (status == "running" || status == "waiting")
            let failed = status == "failed" || (group.result?.isError ?? false)
            // 0 读作「运行态没报过」，回落到规范形态上的耗时（宿主 AgentSpawnCard 同）。
            let duration = state.map(\.durationMs).flatMap { $0 > 0 ? $0 : nil } ?? group.use.canonical?.fields["durationMs"]?.int ?? 0
            let expanded = disclosure.expanded[group.key] ?? false
            rows.append(TranscriptRow(id: group.key, content: .subagent(SubagentRow(
                key: group.key, name: Self.subagentName(group.use),
                stepCount: group.steps.isEmpty ? (state?.toolUses ?? 0) : group.steps.count,
                durationMs: !running && duration > 0 ? duration : nil,
                running: running, failed: failed, expanded: expanded
            ))))
            guard expanded else { return }
            let outcome: PendingOutcome = running ? .running : (status == "failed" ? .failed : status == "canceled" ? .canceled : .unknown)
            appendBlock(
                key: "\(group.key):activity", steps: group.steps, summary: ActivityRules.summarize(group.steps, unresolvedFailed: outcome == .failed),
                running: running, defaultExpanded: true, durationMs: 0, depth: 1, pendingOutcome: outcome
            )
        }

        static func subagentName(_ use: ToolUse) -> String {
            let candidates = [
                use.canonical?.fields["taskDescription"]?.string, use.subagent?.taskDescription,
                use.canonical?.fields["subagentType"]?.string, use.subagent?.subagentType,
            ]
            return candidates.compactMap { $0 }.first { !$0.isEmpty } ?? ToolUse.displayName(use.name)
        }
    }
}
