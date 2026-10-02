import AgentreDesign
import AgentreDomain
import SwiftUI
import UIKit

/// 转录里的审批 / 提问卡片：接在 `TranscriptView(model:agentName:card:)` 的插入点上，
/// 内联于转录流，不升起模态。
///
/// 卡片只如实呈现工具名与原始输入，由用户判断；外观只随作答状态变，不随内容变。
public struct ApprovalCard: View {
    private let card: TranscriptCard
    private let model: ApprovalCardsModel

    public init(_ card: TranscriptCard, model: ApprovalCardsModel) {
        self.card = card
        self.model = model
    }

    public var body: some View {
        switch card {
        case .permission(let request):
            ApprovalPermissionCard(request: request, model: model)
        case .question(let request):
            ApprovalQuestionCard(request: request, model: model)
        case .tool:
            // 计划审批等带出组 canonical 的调用不归这两张卡。
            EmptyView()
        }
    }
}

// MARK: 权限

private struct ApprovalPermissionCard: View {
    let request: PermissionRequest
    let model: ApprovalCardsModel

    var body: some View {
        let state = model.state(of: request)
        let input = ApprovalInput(toolName: request.toolName, input: request.input, cwd: model.conversation.cwd)
        let expanded = model.isExpanded(request.requestID)
        ApprovalCardFrame(tone: state.tone) {
            HStack(spacing: 7) {
                Image(.shieldAlert)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.token(state.tone))
                    .accessibilityHidden(true)
                ApprovalPermissionTitle(input: input)
                    .font(.agentre(FontRole(size: 12.5, weight: .semibold, relativeTo: .footnote)))
                    .foregroundStyle(.token(state.tone))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let settled = state.settledKey {
                    ApprovalPill(key: settled, tone: state.tone)
                }
            }
            ApprovalMachineBlock(input: input, showsFullText: !input.isLong || expanded)
            if input.isLong {
                Button {
                    model.toggleExpanded(request.requestID)
                } label: {
                    Text(expanded ? "input.collapse" : "input.expand", tableName: "Cards", bundle: .module)
                        .font(.agentre(.footnote, weight: .semibold))
                        .foregroundStyle(.token(.primary))
                }
                .hitTarget()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if case .open(let submitting, let failed) = state {
                if failed {
                    Text("permission.submitFailed", tableName: "Cards", bundle: .module)
                        .font(.agentre(.footnote))
                        .foregroundStyle(.token(.coral))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                ApprovalButtonRow {
                    ForEach(PermissionDisposition.allCases, id: \.self) { disposition in
                        ApprovalButton(key: disposition.titleKey, weight: disposition.weight) {
                            Task { await model.submit(disposition, for: request) }
                        }
                        .disabled(submitting)
                    }
                }
            }
        }
    }
}

/// 标题按请求种类：命令类为「请求执行命令」，其余为「请求使用」加等宽工具名（工具名是机器产出的）。
private struct ApprovalPermissionTitle: View {
    let input: ApprovalInput

    var body: some View {
        if input.command != nil {
            Text("permission.title.command", tableName: "Cards", bundle: .module)
        } else {
            Text("permission.title.tool \(Text(verbatim: input.toolName).font(.agentre(FontRole(size: 12.5, weight: .semibold, relativeTo: .footnote), mono: true)))",
                 tableName: "Cards", bundle: .module)
        }
    }
}

/// 执行目录与命令合成一块，按终端的样子排：目录在上、`$` 与命令在下，共用一层浅底。
private struct ApprovalMachineBlock: View {
    let input: ApprovalInput
    let showsFullText: Bool

    var body: some View {
        let shown = showsFullText ? input.text : input.summary
        if !input.cwd.isEmpty || !shown.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if !input.cwd.isEmpty {
                    Text(verbatim: input.cwd)
                        .font(.agentre(.caption2, mono: true))
                        .foregroundStyle(.token(.ink3))
                }
                if input.command != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(verbatim: "$")
                            .foregroundStyle(.token(.ink3))
                        Text(verbatim: shown)
                            .foregroundStyle(.token(.ink))
                    }
                } else if !shown.isEmpty {
                    Text(verbatim: shown)
                        .foregroundStyle(.token(.ink))
                }
            }
            .font(.agentre(.footnote, mono: true))
            .lineLimit(showsFullText ? nil : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(.token(.bg), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: 提问

private struct ApprovalQuestionCard: View {
    let request: QuestionRequest
    let model: ApprovalCardsModel

    var body: some View {
        let state = model.state(of: request)
        ApprovalCardFrame(tone: state.tone) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.agentre(.subheadline, weight: .semibold))
                    .foregroundStyle(.token(state.tone))
                    .accessibilityHidden(true)
                Text(verbatim: "user_ask")
                    .font(.agentre(.subheadline, mono: true, weight: .semibold))
                    .foregroundStyle(.token(.ink))
                Spacer(minLength: 8)
                if let settled = state.settledKey {
                    ApprovalPill(key: settled, tone: state.tone)
                }
            }
            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: question.question)
                        .font(.agentre(.subheadline, weight: .semibold))
                        .foregroundStyle(.token(.ink))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !question.header.isEmpty {
                        Text(verbatim: question.header)
                            .font(.agentre(.caption, weight: .medium))
                            .foregroundStyle(.token(.primary))
                    }
                    Text(question.multiSelect ? "question.multi" : "question.single", tableName: "Cards", bundle: .module)
                        .font(.agentre(.caption, weight: .semibold))
                        .foregroundStyle(.token(.ink2))
                }
                if case .open(let submitting) = state {
                    let selected = model.selectedLabels(index, of: request)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                        ApprovalOptionButton(option: option, multiSelect: question.multiSelect, selected: selected.contains(option.label)) {
                            model.toggleOption(option.label, at: index, of: request)
                        }
                        .disabled(submitting)
                    }
                    ApprovalAnswerField(
                        text: Binding(get: { model.answer(index, of: request) }, set: { model.setAnswer($0, at: index, of: request) }),
                        placeholder: LocalizedCopy("question.placeholder", table: "Cards"),
                        isSecure: question.isSecret
                    )
                    .padding(.horizontal, 10)
                    .background(.token(.surface2), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.token(.primary).opacity(selected.contains(QuestionAnswer.otherLabel) ? 0.6 : 0), lineWidth: 1)
                    }
                }
            }
            if case .open = state, let error = model.inputError(of: request) {
                Text(error.messageKey, tableName: "Cards", bundle: .module)
                    .font(.agentre(.footnote))
                    .foregroundStyle(.token(.coral))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state == .expired {
                Text("question.expiredDetail", tableName: "Cards", bundle: .module)
                    .font(.agentre(.footnote))
                    .foregroundStyle(.token(.coral))
            }
            if case .open(let submitting) = state {
                ApprovalButtonRow {
                    ApprovalButton(key: "question.skip", weight: .outline) {
                        Task { await model.skip(request) }
                    }
                    .disabled(submitting)
                    // 与宿主同：不因没答完而禁用，点了由核对给出那句报错。
                    ApprovalButton(key: "question.submit", weight: .solid) {
                        Task { await model.submitAnswers(for: request) }
                    }
                    .disabled(submitting)
                }
            }
        }
    }
}

/// 一个选项：整行可点，单选画圆点、多选画方框，选中时铺主色浅底。
private struct ApprovalOptionButton: View {
    let option: AskOption
    let multiSelect: Bool
    let selected: Bool
    let action: () -> Void

    private var symbol: String {
        switch (multiSelect, selected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.token(selected ? .primary : .ink2))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: option.label)
                        .font(.agentre(.subheadline, weight: .semibold))
                        .foregroundStyle(.token(selected ? .primary : .ink))
                    if !option.description.isEmpty {
                        Text(verbatim: option.description)
                            .font(.agentre(.footnote))
                            .foregroundStyle(.token(.ink2))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.token(selected ? .primary : .surface2).opacity(selected ? 0.14 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.token(selected ? .primary : .ink2).opacity(selected ? 0.6 : 0.25), lineWidth: 1)
            }
        }
        .hitTarget()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 作答框。SwiftUI 的 TextField 背后的文本框只有一行字高，外面补 frame 撑不大命中区；
/// 这里让文本框本身长高。取 44pt 时在列表行里实测真实命中区只剩 43pt，故多留 4pt。
private struct ApprovalAnswerField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: LocalizedCopy
    var isSecure = false

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.isSecureTextEntry = isSecure
        field.font = UIFont.agentre(.subheadline)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = ColorToken.ink.uiColor
        field.tintColor = ColorToken.primary.uiColor
        field.showPlaceholder(placeholder, in: context.environment.locale)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.showPlaceholder(placeholder, in: context.environment.locale)
        if field.text != text { field.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? field.intrinsicContentSize.width, height: max(minimumHitTargetSide + 4, field.intrinsicContentSize.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: ApprovalAnswerField

        init(parent: ApprovalAnswerField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }
    }
}

// MARK: 共用形态

/// 卡片外框：一圈随状态取色的边框，标题直接排在卡片里，不铺底色带。
private struct ApprovalCardFrame<Content: View>: View {
    let tone: ColorToken
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.token(tone), lineWidth: 1))
        .padding(.vertical, 6)
    }
}

/// 处置一行：按标签宽度排、右对齐。稿子的内边距排不下（英文的三枚在 331pt 宽的卡片里）时先收窄按钮的
/// 内边距，仍排不下才自上而下叠放，仍右对齐。相邻两枚的命中区之间隔着 `spacing` 的死区，不随之收窄。
private struct ApprovalButtonRow<Content: View>: View {
    static var spacing: CGFloat { 10 }
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Self.spacing) { content }
            HStack(spacing: Self.spacing) { content }
                .environment(\.approvalButtonInset, 8)
            VStack(alignment: .trailing, spacing: Self.spacing) { content }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

extension EnvironmentValues {
    /// 处置按钮标签两侧的内边距：稿子 12。
    @Entry fileprivate var approvalButtonInset: CGFloat = 12
}

/// 处置按钮：绘制 34pt 高、不配图标；命中区由 hitTarget() 补满 44×44。
private struct ApprovalButton: View {
    let key: LocalizedStringKey
    let weight: ApprovalButtonWeight
    let action: () -> Void
    /// 离线时处置发不出去：点不动，而不是点了再报失败。
    @Environment(\.isOffline) private var isOffline
    @Environment(\.approvalButtonInset) private var inset

    var body: some View {
        Button(action: action) {
            Text(key, tableName: "Cards", bundle: .module)
                .font(.agentre(.subheadline, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.token(weight.foreground))
                .padding(.horizontal, inset)
                .frame(height: 34)
                .background {
                    switch weight {
                    case .outline:
                        RoundedRectangle(cornerRadius: 9).strokeBorder(.token(.lineStrong), lineWidth: 1)
                    case .tinted:
                        RoundedRectangle(cornerRadius: 9).fill(.token(.surface2))
                    case .solid:
                        RoundedRectangle(cornerRadius: 9).fill(.token(.primary))
                    }
                }
        }
        .hitTarget()
        .disabled(isOffline)
    }
}

private struct ApprovalPill: View {
    let key: LocalizedStringKey
    let tone: ColorToken

    var body: some View {
        Text(key, tableName: "Cards", bundle: .module)
            .font(.agentre(.caption, weight: .semibold))
            .foregroundStyle(.token(tone))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.token(tone).opacity(0.12), in: Capsule())
    }
}

/// 处置按钮的视觉分量：承诺越大的越不像顺手一点的东西。
enum ApprovalButtonWeight: Equatable {
    case outline, tinted, solid

    fileprivate var foreground: ColorToken {
        switch self {
        case .outline: .ink2
        case .tinted: .ink
        case .solid: .primaryInk
        }
    }
}

extension PermissionDisposition {
    /// 拒绝描边、本会话始终允许浅底、仅本次允许主色实心。
    var weight: ApprovalButtonWeight {
        switch self {
        case .reject: .outline
        case .allowForSession: .tinted
        case .allowOnce: .solid
        }
    }

    /// 宿主原文：common.reject、canonical.toolPermission.allowSession / allowOnce。
    fileprivate var titleKey: LocalizedStringKey {
        switch self {
        case .reject: "permission.reject"
        case .allowForSession: "permission.allowForSession"
        case .allowOnce: "permission.allowOnce"
        }
    }
}

extension ApprovalPermissionState {
    /// 边框与盾牌的颜色：等你处理为琥珀，允许为绿，拒绝为红。
    fileprivate var tone: ColorToken {
        switch self {
        case .open: .amber
        case .allowed, .allowedForSession: .run
        case .denied: .coral
        }
    }

    fileprivate var settledKey: LocalizedStringKey? {
        switch self {
        case .open: nil
        case .allowed: "permission.allowed"
        case .allowedForSession: "permission.allowedForSession"
        case .denied: "permission.denied"
        }
    }
}

extension QuestionInputError {
    /// 宿主原文：canonical.userAsk.errors.optionRequired / otherRequired。
    fileprivate var messageKey: LocalizedStringKey {
        switch self {
        case .optionRequired: "question.errors.optionRequired"
        case .otherRequired: "question.errors.otherRequired"
        }
    }
}

extension ApprovalQuestionState {
    fileprivate var tone: ColorToken {
        switch self {
        case .open: .amber
        case .answered: .run
        case .skipped, .expired: .ink2
        }
    }

    fileprivate var settledKey: LocalizedStringKey? {
        switch self {
        case .open: nil
        case .answered: "question.answered"
        case .skipped: "question.skipped"
        case .expired: "question.expired"
        }
    }
}
