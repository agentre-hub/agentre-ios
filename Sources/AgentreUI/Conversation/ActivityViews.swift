import AgentreDesign
import AgentreDomain
import SwiftUI

// 活动块不套容器：组头与步骤行都没有边框、底色或圆角，展开后的步骤只靠一条左侧竖线归组。
// 它是消息正文里的一段，不是消息旁边的一个对象。

private let indentPerDepth: CGFloat = 16

/// 组头：展开指示、步数、分类汇总、耗时。运行态只留脉冲点与「执行中 · N 步」；
/// 失败与后台计数单列在末尾，永不参与截断。
struct ActivityHeaderView: View {
    let header: ActivityHeaderRow
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Chevron(expanded: header.expanded, size: 14, tint: .ink3)
                if header.running {
                    RunningDot()
                    Text("activity.running \(header.summary.steps)", tableName: "Conversation", bundle: .module)
                        .font(.agentre(stepsRole, mono: true))
                        .foregroundStyle(.token(.ink2))
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                } else {
                    Text("activity.steps \(header.summary.steps)", tableName: "Conversation", bundle: .module)
                        .font(.agentre(stepsRole, mono: true))
                        .foregroundStyle(.token(.ink2))
                        .layoutPriority(1)
                    SummaryText(summary: header.summary)
                }
                Counts(summary: header.summary)
                if let durationMs = header.durationMs {
                    ActivityDuration(durationMs: durationMs)
                }
            }
            .lineLimit(1)
            .padding(.vertical, 6)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(header.depth) * indentPerDepth + 6)
            .contentShape(Rectangle())
        }
        .hitTarget()
    }

    private var stepsRole: FontRole { FontRole(size: 11.5, weight: .semibold, relativeTo: .caption) }
}

/// 运行中被省略的前几步收成的一行：带被省略部分的汇总与失败数。点开即全部摊开。
struct ElidedStepsView: View {
    let elided: ElidedRow
    let showAll: () -> Void

    var body: some View {
        Button(action: showAll) {
            HStack(spacing: 8) {
                Image(.chevronsUp)
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.token(.ink3))
                    .accessibilityHidden(true)
                Text("activity.elided \(elided.count)", tableName: "Conversation", bundle: .module)
                    .layoutPriority(1)
                SummaryText(summary: elided.summary)
                Counts(summary: elided.summary)
            }
            .font(.agentre(FontRole(size: 11, relativeTo: .caption2)))
            .foregroundStyle(.token(.ink3))
            .lineLimit(1)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .hitTarget()
        .modifier(StepRail(depth: elided.depth))
    }
}

/// 一步。三档权重只体现在字重与前景色上：行高、内边距与交互完全相同。
/// 行尾按工具种类写结果（「N 处 / N 行 / +N / 失败」）；运行中的一步图标位换成脉冲点，不写耗时。
struct ActivityStepView: View {
    let step: StepRow
    let toggle: () -> Void

    var body: some View {
        let rail = StepRail(depth: step.depth, visible: !step.standalone)
        Button(action: toggle) {
            HStack(spacing: 9) {
                if step.standalone || step.expanded {
                    Chevron(expanded: step.expanded, size: 12, tint: .ink3)
                }
                if step.facts.pending == .running {
                    RunningDot(label: Text("activity.row.running", tableName: "Conversation", bundle: .module))
                } else {
                    Image(icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.token(step.facts.failed ? .coral : .ink3))
                        .accessibilityHidden(true)
                }
                HStack(spacing: 8) {
                    name
                        .font(.agentre(Self.rowFont, mono: true, weight: nameWeight))
                        .layoutPriority(1)
                    summary
                        .truncationMode(.middle)
                }
                .font(.agentre(Self.rowFont, mono: true))
                .foregroundStyle(.token(nameToken))
                .frame(maxWidth: .infinity, alignment: .leading)
                StepTrailing(facts: step.facts)
            }
            .lineLimit(1)
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
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

    private var icon: AgentreIcon {
        if case .thinking = step.step { return .brain }
        switch step.category ?? .other {
        case .command: return .terminal
        case .edit, .write: return .filePen
        case .read: return step.step.toolUse?.isSearch == true ? .fileSearch : .fileText
        case .other: return .square
        }
    }

    private static let rowFont = FontRole(size: 11, relativeTo: .caption2)

    private var nameWeight: FontWeight {
        step.weight == .write ? .semibold : .regular
    }

    /// 写层、失败与正在跑的那一步用正文色，其余次级色。
    private var nameToken: ColorToken {
        step.weight == .read && !step.facts.failed && step.facts.pending != .running ? .ink2 : .ink
    }
}

/// 行尾的结果：按工具种类的「N 处 / N 行 / +N」，失败写「失败」；未落定的按归属报，运行中不写。
private struct StepTrailing: View {
    let facts: StepFacts

    var body: some View {
        HStack(spacing: 6) {
            if let pending = facts.pending {
                PendingMarker(outcome: pending)
            } else if let result = facts.result {
                switch result {
                case .matches(let count):
                    Text("activity.row.matches \(count)", tableName: "Conversation", bundle: .module)
                case .lines(let count):
                    Text("activity.row.lines \(count)", tableName: "Conversation", bundle: .module)
                case .changed(let plus, let minus):
                    Text("activity.plus \(plus)", tableName: "Conversation", bundle: .module)
                    if minus > 0 {
                        Text("activity.minus \(minus)", tableName: "Conversation", bundle: .module)
                    }
                case .failed:
                    Text("activity.row.failed", tableName: "Conversation", bundle: .module)
                        .foregroundStyle(.token(.coral))
                }
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
            }
        }
        .font(.agentre(.caption2, mono: true))
        .foregroundStyle(.token(.ink3))
        .lineLimit(1)
    }
}

/// 没有结果的一步：运行中什么都不写（图标位已是脉冲点，没有来源的耗时不编）；
/// 已终结却没配到结果的按归属报，不再转圈。
private struct PendingMarker: View {
    let outcome: PendingOutcome

    var body: some View {
        switch outcome {
        case .running:
            EmptyView()
        case .failed:
            Text("activity.row.failed", tableName: "Conversation", bundle: .module)
                .foregroundStyle(.token(.coral))
        case .canceled:
            Text("activity.row.canceled", tableName: "Conversation", bundle: .module)
        case .unknown:
            Text("activity.row.unknown", tableName: "Conversation", bundle: .module)
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
        .font(.agentre(FontRole(size: 11, relativeTo: .caption2), mono: true))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.leading, 28)
        .modifier(StepRail(depth: step.depth, visible: !step.standalone))
    }

    private static func display(_ value: JSONValue) -> String {
        String((value.string ?? value.compactText).prefix(maxCharacters))
    }
}

/// Subagent 折叠态：`surface` 底、一行高的卡片，一枚展开指示、「Subagent · 名称」、右端「N 步 · 耗时」。
/// 分类汇总不进这一行，展开后由它自己的活动块给出。
struct SubagentLineView: View {
    let subagent: SubagentRow
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Chevron(expanded: subagent.expanded, size: 13, tint: .primary)
                if subagent.failed {
                    // 失败不只靠红色（规格「状态不得仅以颜色区分」）：与失败步同一句「失败」。
                    Image(systemName: "exclamationmark.triangle")
                        .font(.agentre(.caption))
                        .foregroundStyle(.token(.coral))
                        .accessibilityLabel(Text("activity.row.failed", tableName: "Conversation", bundle: .module))
                }
                Text("subagent.title \(subagent.name)", tableName: "Conversation", bundle: .module)
                    .font(.agentre(.footnote, weight: .semibold))
                    .foregroundStyle(.token(subagent.failed ? .coral : .primary))
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if subagent.running { RunningDot() }
                HStack(spacing: 4) {
                    Text("subagent.steps \(subagent.stepCount)", tableName: "Conversation", bundle: .module)
                    if let durationMs = subagent.durationMs {
                        Separator()
                        Text(verbatim: ClockDuration.text(milliseconds: durationMs))
                    }
                }
                .font(.agentre(.caption2, mono: true))
                .foregroundStyle(.token(.ink3))
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.token(.surface), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.token(.line), lineWidth: 1) }
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
        .font(.agentre(.caption))
        .foregroundStyle(.token(.ink3))
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
                    Text("activity.plus \(plus)", tableName: "Conversation", bundle: .module)
                }
                if let minus = part.minus, minus > 0 {
                    Text("activity.minus \(minus)", tableName: "Conversation", bundle: .module)
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
            .font(.agentre(.caption))
            .foregroundStyle(.token(.run))
            .layoutPriority(2)
        }
        if summary.failures > 0 {
            Text("activity.summary.failures \(summary.failures)", tableName: "Conversation", bundle: .module)
                .font(.agentre(.caption, weight: .semibold))
                .foregroundStyle(.token(.coral))
                .layoutPriority(2)
        }
    }
}

/// 组头耗时：「分:秒」。
private struct ActivityDuration: View {
    let durationMs: Int

    var body: some View {
        Text(verbatim: ClockDuration.text(milliseconds: durationMs))
            .font(.agentre(FontRole(size: 11, relativeTo: .caption2), mono: true))
            .foregroundStyle(.token(.ink3))
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
    let size: CGFloat
    let tint: ColorToken

    var body: some View {
        Image(expanded ? .chevronDown : .chevronRight)
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(.token(tint))
            .accessibilityHidden(true)
    }
}

/// 运行中的脉冲点：一圈淡晕里一枚实心点。
private struct RunningDot: View {
    /// 它独自表示「运行中」时（步骤的图标位）给读屏的说法；旁边已有文字时不念。
    var label: Text?
    @State private var dim = false

    var body: some View {
        ZStack {
            Circle().fill(.token(.run)).opacity(0.25)
            Circle().fill(.token(.run)).frame(width: 6, height: 6)
        }
        .frame(width: 13, height: 13)
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityHidden(label == nil)
        .accessibilityLabel(label ?? Text(verbatim: ""))
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
                    .fill(.token(.line))
                    .frame(width: 1)
                    .padding(.trailing, 6)
                    .accessibilityHidden(true)
            }
            content
        }
        .padding(.leading, CGFloat(depth) * indentPerDepth + (visible ? 6 : 0))
    }
}
