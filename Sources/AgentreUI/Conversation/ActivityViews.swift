import AgentreDesign
import AgentreDomain
import SwiftUI

// 活动块不套容器：组头与步骤行都没有边框、底色或圆角，展开后的步骤只靠一条左侧竖线归组。
// 它是消息正文里的一段，不是消息旁边的一个对象。

private let indentPerDepth: CGFloat = 16

/// 组头：展开指示、活动图标、步数、分类汇总、耗时。运行态只留脉冲点与「执行中 · N 步」；
/// 失败与后台计数单列在末尾，永不参与截断。
struct ActivityHeaderView: View {
    let header: ActivityHeaderRow
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Chevron(expanded: header.expanded)
                Image(systemName: "square.stack.3d.up")
                    .font(.caption2)
                    .foregroundStyle(.token(.ink2))
                    .accessibilityHidden(true)
                if header.running {
                    RunningDot()
                    Text("activity.running \(header.summary.steps)", tableName: "Conversation", bundle: .module)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                } else {
                    Text("activity.steps \(header.summary.steps)", tableName: "Conversation", bundle: .module)
                        .layoutPriority(1)
                    SummaryText(summary: header.summary)
                }
                Counts(summary: header.summary)
                if let durationMs = header.durationMs {
                    ActivityDuration(durationMs: durationMs)
                }
            }
            .font(.footnote)
            .foregroundStyle(.token(.ink2))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(header.depth) * indentPerDepth)
            .contentShape(Rectangle())
        }
        .hitTarget()
    }
}

/// 运行中被省略的前几步收成的一行：带被省略部分的汇总与失败数。点开即全部摊开。
struct ElidedStepsView: View {
    let elided: ElidedRow
    let showAll: () -> Void

    var body: some View {
        Button(action: showAll) {
            HStack(spacing: 6) {
                Chevron(expanded: false)
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text("activity.elided \(elided.count)", tableName: "Conversation", bundle: .module)
                    .layoutPriority(1)
                SummaryText(summary: elided.summary)
                Counts(summary: elided.summary)
            }
            .font(.footnote.monospaced())
            .foregroundStyle(.token(.ink2))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .hitTarget()
        .modifier(StepRail(depth: elided.depth))
    }
}

/// 一步。三档权重只体现在字重与前景色上：行高、内边距与交互完全相同。
struct ActivityStepView: View {
    let step: StepRow
    let toggle: () -> Void

    var body: some View {
        let rail = StepRail(depth: step.depth, visible: !step.standalone)
        Button(action: toggle) {
            HStack(spacing: 6) {
                Chevron(expanded: step.expanded)
                    .opacity(step.standalone || step.expanded ? 1 : 0)
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.token(step.facts.failed ? .coral : iconToken))
                    .accessibilityHidden(true)
                name
                    .font(.footnote.monospaced().weight(nameWeight))
                    .foregroundStyle(.token(step.facts.failed ? .coral : nameToken))
                    .layoutPriority(1)
                summary
                    .font(.footnote.monospaced())
                    .foregroundStyle(.token(.ink2))
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StepTrailing(facts: step.facts)
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .hitTarget()
        .modifier(rail)
    }

    @ViewBuilder private var name: some View {
        if case .thinking = step.step {
            Text("activity.row.thinking", tableName: "Conversation", bundle: .module)
        } else {
            Text(verbatim: step.label.name)
        }
    }

    @ViewBuilder private var summary: some View {
        if case .thinking(_, let text) = step.step {
            Text("activity.row.thinkingMeta \(text.count)", tableName: "Conversation", bundle: .module)
        } else if let count = step.label.fileCount {
            Text("activity.row.files \(count)", tableName: "Conversation", bundle: .module)
        } else {
            Text(verbatim: step.label.summary)
        }
    }

    private var icon: String {
        if step.facts.failed { return "exclamationmark.triangle" }
        if case .thinking = step.step { return "brain" }
        switch step.category ?? .other {
        case .command: return "terminal"
        case .edit: return "pencil"
        case .write: return "doc.badge.plus"
        case .read: return "magnifyingglass"
        case .other: return "wrench.and.screwdriver"
        }
    }

    private var nameWeight: Font.Weight {
        switch step.weight {
        case .read: .regular
        case .neutral: .medium
        case .write: .semibold
        }
    }

    private var nameToken: ColorToken { step.weight == .read ? .ink2 : .ink }
    private var iconToken: ColorToken { step.weight == .write ? .ink : .ink2 }
}

/// 行尾的实义信息：写操作报增删行，失败报 exit N，未落定报状态标记，其余报结果规模或预览。
private struct StepTrailing: View {
    let facts: StepFacts

    var body: some View {
        HStack(spacing: 6) {
            if let plus = facts.plus, plus > 0 {
                Text("activity.plus \(plus)", tableName: "Conversation", bundle: .module)
                    .fontWeight(.semibold)
                    .foregroundStyle(.token(.run))
            }
            if let minus = facts.minus, minus > 0 {
                Text("activity.minus \(minus)", tableName: "Conversation", bundle: .module)
                    .fontWeight(.semibold)
                    .foregroundStyle(.token(.coral))
            }
            if let pending = facts.pending {
                PendingMarker(outcome: pending)
            } else if let exitCode = facts.exitCode {
                Text("activity.row.exit \(exitCode)", tableName: "Conversation", bundle: .module)
                    .foregroundStyle(.token(facts.failed ? .coral : .ink2))
            } else if facts.failed {
                Text("activity.row.failed", tableName: "Conversation", bundle: .module)
                    .foregroundStyle(.token(.coral))
            }
            if facts.pending == nil, facts.backgroundRunning {
                HStack(spacing: 4) {
                    RunningDot()
                    if let taskID = facts.backgroundTaskID {
                        Text("activity.row.background \(taskID)", tableName: "Conversation", bundle: .module)
                    } else {
                        Text("activity.row.background", tableName: "Conversation", bundle: .module)
                    }
                }
                .foregroundStyle(.token(.run))
            } else if facts.pending == nil, !facts.failed {
                if let lines = facts.lines {
                    Text("activity.row.lines \(lines)", tableName: "Conversation", bundle: .module)
                        .foregroundStyle(.token(.ink2))
                } else if let preview = facts.preview {
                    Text(verbatim: preview)
                        .foregroundStyle(.token(.ink2))
                        .frame(maxWidth: 120, alignment: .trailing)
                }
            }
        }
        .font(.caption.monospaced())
        .lineLimit(1)
    }
}

/// 没有结果的一步：运行中带脉冲点；已终结却没配到结果的按归属报，不再转圈。
private struct PendingMarker: View {
    let outcome: PendingOutcome

    var body: some View {
        switch outcome {
        case .running:
            HStack(spacing: 4) {
                RunningDot()
                Text("activity.row.running", tableName: "Conversation", bundle: .module)
            }
            .foregroundStyle(.token(.run))
        case .failed:
            Text("activity.row.failed", tableName: "Conversation", bundle: .module)
                .foregroundStyle(.token(.coral))
        case .canceled:
            Text("activity.row.canceled", tableName: "Conversation", bundle: .module)
                .foregroundStyle(.token(.ink2))
        case .unknown:
            Text("activity.row.unknown", tableName: "Conversation", bundle: .module)
                .foregroundStyle(.token(.ink2))
        }
    }
}

/// 点开的一步：参数与结果，机器产出的内容一律等宽。
struct ActivityStepDetailView: View {
    let step: StepRow
    private static let maxCharacters = 20_000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let input = step.step.toolUse?.input, !input.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(input.keys.sorted(), id: \.self) { key in
                        Text(verbatim: "\(key): \(Self.display(input[key]!))")
                            .foregroundStyle(.token(.ink2))
                    }
                }
            }
            let result = step.facts.resultText
            if !result.isEmpty {
                Text(verbatim: String(result.prefix(Self.maxCharacters)))
                    .foregroundStyle(.token(step.facts.failed ? .coral : .ink))
            }
        }
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.leading, 20)
        .modifier(StepRail(depth: step.depth, visible: !step.standalone))
    }

    private static func display(_ value: JSONValue) -> String {
        String((value.string ?? value.compactText).prefix(maxCharacters))
    }
}

/// Subagent 折叠态：一行高的卡片壳，一枚展开指示、「Subagent · 名称」、右端步数与耗时。
/// 分类汇总不进这一行，展开后由它自己的活动块给出。
struct SubagentLineView: View {
    let subagent: SubagentRow
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Chevron(expanded: subagent.expanded)
                if subagent.failed {
                    // 失败不只靠红色（规格「状态不得仅以颜色区分」）：与失败步同一枚图标、同一句「失败」。
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.token(.coral))
                        .accessibilityLabel(Text("activity.row.failed", tableName: "Conversation", bundle: .module))
                }
                Text("subagent.title \(subagent.name)", tableName: "Conversation", bundle: .module)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.token(subagent.failed ? .coral : .ink))
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if subagent.running { RunningDot() }
                Text("subagent.steps \(subagent.stepCount)", tableName: "Conversation", bundle: .module)
                    .font(.caption.monospaced())
                if let durationMs = subagent.durationMs {
                    ActivityDuration(durationMs: durationMs)
                        .font(.caption.monospaced())
                }
            }
            .foregroundStyle(.token(.ink2))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.token(.surface), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.token(.surface2), lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .hitTarget()
        .padding(.vertical, 2)
    }
}

// MARK: 组件

/// 汇总：类目按规则给定的顺序原样输出，被截掉的只补一个省略号。
private struct SummaryText: View {
    let summary: ActivitySummary

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(summary.parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Separator() }
                SummaryPart(part: part)
            }
            if summary.truncated {
                if !summary.parts.isEmpty { Separator() }
                Text(verbatim: "…")
            }
        }
        .font(.footnote.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

private struct SummaryPart: View {
    let part: ActivitySummaryPart

    var body: some View {
        switch part.category {
        case .thinking: Text("activity.summary.thinking \(part.count)", tableName: "Conversation", bundle: .module)
        case .read: Text("activity.summary.read \(part.count)", tableName: "Conversation", bundle: .module)
        case .edit:
            HStack(spacing: 3) {
                Text("activity.summary.edit \(part.files ?? part.count)", tableName: "Conversation", bundle: .module)
                if let plus = part.plus, plus > 0 {
                    Text("activity.plus \(plus)", tableName: "Conversation", bundle: .module).foregroundStyle(.token(.run))
                }
                if let minus = part.minus, minus > 0 {
                    Text("activity.minus \(minus)", tableName: "Conversation", bundle: .module).foregroundStyle(.token(.coral))
                }
            }
        case .write: Text("activity.summary.write \(part.count)", tableName: "Conversation", bundle: .module)
        case .command: Text("activity.summary.command \(part.count)", tableName: "Conversation", bundle: .module)
        case .other: Text("activity.summary.other \(part.count)", tableName: "Conversation", bundle: .module)
        }
    }
}

/// 后台与失败计数：在可伸缩的汇总之外，挤不下时先裁汇总。
private struct Counts: View {
    let summary: ActivitySummary

    var body: some View {
        if summary.backgroundRunning > 0 {
            HStack(spacing: 3) {
                RunningDot()
                Text("activity.summary.background \(summary.backgroundRunning)", tableName: "Conversation", bundle: .module)
            }
            .font(.footnote.monospaced())
            .foregroundStyle(.token(.run))
            .layoutPriority(2)
        }
        if summary.failures > 0 {
            Text("activity.summary.failures \(summary.failures)", tableName: "Conversation", bundle: .module)
                .font(.footnote.monospaced().weight(.semibold))
                .foregroundStyle(.token(.coral))
                .layoutPriority(2)
        }
    }
}

private struct ActivityDuration: View {
    let durationMs: Int

    var body: some View {
        Text("activity.duration \(String(format: "%.1f", Double(durationMs) / 1000))", tableName: "Conversation", bundle: .module)
            .monospacedDigit()
            .layoutPriority(2)
    }
}

private struct Separator: View {
    var body: some View {
        Text(verbatim: "·").accessibilityHidden(true)
    }
}

private struct Chevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.token(.ink2))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}

/// 运行中的脉冲点。
private struct RunningDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.token(.run))
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

/// 组内步骤的左侧竖线与缩进。
private struct StepRail: ViewModifier {
    let depth: Int
    var visible = true

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            if visible {
                Rectangle()
                    .fill(.token(.surface2))
                    .frame(width: 1)
                    .padding(.trailing, 8)
                    .accessibilityHidden(true)
            }
            content
        }
        .padding(.leading, CGFloat(depth) * indentPerDepth + (visible ? 6 : 0))
    }
}
