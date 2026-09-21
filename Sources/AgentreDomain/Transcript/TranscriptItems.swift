import Foundation

/// 一条助手消息的块 → 渲染项，移植自宿主 agentre-ui 的 transcript-rows.ts（buildRenderItems +
/// groupActivityItems）：工具与结果按调用 id 配对；Subagent 的内层块归它自己；已批准的审批被
/// 随后同名的调用消费；连续的思考与可折叠的工具折成一个活动块，正文与四类出组项打断聚合。
public enum TranscriptItems {
    public static func build(messageID: String, blocks: [TranscriptBlock], liveThinking: String = "", liveText: String = "") -> [TranscriptItem] {
        var children: [String: [TranscriptBlock]] = [:]
        for block in blocks {
            if let parent = block.parentID { children[parent, default: []].append(block) }
        }

        var items: [Pending] = []
        var pendingTools: [String: Int] = [:]
        var anonymousTools: [Int] = []
        var skipped = Set<String>()
        var pendingPermissions: [String: [Int]] = [:]

        func appendText(_ text: String, streaming: Bool) {
            guard !text.isEmpty else { return }
            if case .text(let previous, let wasStreaming)? = items.last {
                items[items.count - 1] = .text(previous + text, streaming: wasStreaming || streaming)
            } else {
                items.append(.text(text, streaming: streaming))
            }
        }

        for block in blocks where block.parentID == nil {
            switch block {
            case .text(let text):
                appendText(text, streaming: false)
            case .thinking(let text):
                items.append(.thinking(text, streaming: false))
            case .toolUse(let use):
                // 提问与退出计划模式的调用由各自的卡片承担，调用本身与其结果都不再出现。
                if isAskUserQuestion(use.name) || use.name == "ExitPlanMode" {
                    if !use.id.isEmpty { skipped.insert(use.id) }
                    continue
                }
                if use.canonical?.kind == Canonical.Kind.agentSpawn {
                    items.append(.subagent(use, nil, children: steps(of: children[use.id] ?? [], messageID: messageID)))
                    // 与宿主同：没有调用 id 的 Subagent 不排进匿名结果的队列。
                    if !use.id.isEmpty { pendingTools[use.id] = items.count - 1 }
                    continue
                }
                if let queue = pendingPermissions[use.name], let first = queue.first {
                    pendingPermissions[use.name] = Array(queue.dropFirst())
                    if case .permission(let request, _) = items[first] { items[first] = .permission(request, consumed: true) }
                }
                items.append(.tool(use, nil))
                if use.id.isEmpty { anonymousTools.append(items.count - 1) } else { pendingTools[use.id] = items.count - 1 }
            case .toolResult(let result):
                if skipped.contains(result.toolCallID) { continue }
                let index = result.toolCallID.isEmpty ? anonymousTools.popLast() : pendingTools.removeValue(forKey: result.toolCallID)
                guard let index else { continue } // 孤儿结果直接丢，不造一张没有调用的卡。
                switch items[index] {
                case .tool(let use, _): items[index] = .tool(use, result)
                case .subagent(let use, _, let steps): items[index] = .subagent(use, result, children: steps)
                default: break
                }
            case .permission(let request):
                items.append(.permission(request, consumed: false))
                if request.resolved, request.allowed, !request.toolName.isEmpty {
                    pendingPermissions[request.toolName, default: []].append(items.count - 1)
                }
            case .question(let request):
                items.append(.question(request))
            }
        }
        if !liveThinking.isEmpty { items.append(.thinking(liveThinking, streaming: liveText.isEmpty)) }
        appendText(liveText, streaming: true)

        let visible = items.filter { if case .permission(_, true) = $0 { return false } else { return true } }
        return group(visible, messageID: messageID)
    }

    // MARK: 聚合

    /// 线性扫一遍：连续可折叠项攒成一段，遇到别的项先结束当前段再原样输出它。顺序与输入一致。
    private static func group(_ items: [Pending], messageID: String) -> [TranscriptItem] {
        var output: [TranscriptItem] = []
        var run: [ActivityStep] = []
        var runStart = 0

        func flush() {
            guard let first = run.first else { return }
            let identity = first.toolUse.flatMap { identityOf($0) } ?? String(runStart)
            output.append(.activity(ActivityGroup(key: "message:\(messageID):activity:\(identity)", steps: run, summary: ActivityRules.summarize(run))))
            run = []
        }

        for (index, item) in items.enumerated() {
            let key = item.key(messageID: messageID, index: index)
            if let step = item.foldableStep(key: key) {
                if run.isEmpty { runStart = index }
                run.append(step)
                continue
            }
            flush()
            output.append(item.rendered(key: key))
        }
        flush()

        // 末尾那段还在流的思考不进组，于是它暂时排在活动块后面；把这段错位标在活动块上，
        // 渲染层才不会据「后面还有一行」断定这一组已经落定。
        if case .thinking(_, _, true)? = output.last, output.count >= 2, case .activity(var group) = output[output.count - 2] {
            group.growing = true
            output[output.count - 2] = .activity(group)
        }
        return output
    }

    private static func steps(of blocks: [TranscriptBlock], messageID: String) -> [ActivityStep] {
        var steps: [ActivityStep] = []
        var index: [String: Int] = [:]
        for block in blocks {
            switch block {
            case .toolUse(let use) where use.tier != .out:
                steps.append(.tool(key: "message:\(messageID):tool:\(identityOf(use) ?? "child\(steps.count)")", use: use, result: nil))
                if !use.id.isEmpty { index[use.id] = steps.count - 1 }
            case .toolResult(let result):
                guard let at = index.removeValue(forKey: result.toolCallID), case .tool(let key, let use, _) = steps[at] else { continue }
                steps[at] = .tool(key: key, use: use, result: result)
            default:
                continue
            }
        }
        return steps
    }

    static func isAskUserQuestion(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "askuserquestion" || lowered == "ask_user_question"
    }

    private static func identityOf(_ use: ToolUse) -> String? {
        use.id.isEmpty ? nil : "tool:\(use.id)"
    }

    /// 聚合前的渲染项。
    private enum Pending {
        case text(String, streaming: Bool)
        case thinking(String, streaming: Bool)
        case tool(ToolUse, ToolResult?)
        case subagent(ToolUse, ToolResult?, children: [ActivityStep])
        case permission(PermissionRequest, consumed: Bool)
        case question(QuestionRequest)

        /// 与宿主 itemUIStateKey 同形：message:<id>:<type>:<块身份，缺省为可见下标>。
        func key(messageID: String, index: Int) -> String {
            switch self {
            case .text: "message:\(messageID):text:\(index)"
            case .thinking(_, let streaming): streaming ? "message:\(messageID):thinking:live" : "message:\(messageID):thinking:\(index)"
            case .tool(let use, _), .subagent(let use, _, _): "message:\(messageID):tool:\(identityOf(use) ?? String(index))"
            case .permission(let request, _): "message:\(messageID):permission:\(request.requestID.isEmpty ? String(index) : request.requestID)"
            case .question(let request): "message:\(messageID):ask:\(request.requestID.isEmpty ? String(index) : request.requestID)"
            }
        }

        /// 能不能折进活动块：落定的思考进组，流式思考不进；工具按档判，出组档永不进组。
        func foldableStep(key: String) -> ActivityStep? {
            switch self {
            case .thinking(let text, false): .thinking(key: key, text: text)
            case .tool(let use, let result) where use.tier != .out: .tool(key: key, use: use, result: result)
            default: nil
            }
        }

        func rendered(key: String) -> TranscriptItem {
            switch self {
            case .text(let text, let streaming): .text(key: key, text: text, streaming: streaming)
            case .thinking(let text, let streaming): .thinking(key: key, text: text, streaming: streaming)
            case .tool(let use, let result): .card(key: key, .tool(use, result))
            case .subagent(let use, let result, let children): .subagent(SubagentGroup(key: key, use: use, result: result, steps: children))
            case .permission(let request, _): .card(key: key, .permission(request))
            case .question(let request): .card(key: key, .question(request))
            }
        }
    }
}

extension TranscriptBlock {
    /// 内层（Subagent 里跑的）块的父调用。
    var parentID: String? {
        switch self {
        case .toolUse(let use): use.parentID.flatMap { $0.isEmpty ? nil : $0 }
        case .toolResult(let result): result.parentID.flatMap { $0.isEmpty ? nil : $0 }
        default: nil
        }
    }
}
