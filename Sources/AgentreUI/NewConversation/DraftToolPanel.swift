import AgentreDesign
import AgentreDomain
import SwiftUI

private let table = "NewConversation"
private let composer = "Composer"

/// 草稿工具行的面板：与对话屏更多面板同一形态的分组卡片——权限模式、模型、思考档位三行（Pi 后端没有权限模式），
/// 各自点进选项页。候选按机器 chip 选中的那一档；没选的写「不指定」，按 Agent 与后端的既有配置跑。
/// 这里选的三项只随第一条 runtime.run 带过去（规格「05C 草稿派单」）。
public struct DraftToolPanel: View {
    public enum Page: Hashable {
        case root, permissionMode, model, effort
    }

    private let model: DraftConversationModel
    @State private var page: Page

    public init(model: DraftConversationModel, initialPage: Page = .root) {
        self.model = model
        _page = State(initialValue: initialPage)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch page {
            case .root: root
            case .permissionMode: permissionPage
            case .model: modelPage
            case .effort: effortPage
            }
        }
    }

    // MARK: 根

    private var root: some View {
        GroupedSection(style: .sheet) {
            if model.offersPermissionMode {
                let permission = model.permissionMode.map(permissionModeText)
                GroupedRow(
                    .shieldCheck, title: Text("composer.permissionMode", tableName: composer, bundle: .module),
                    value: permission?.text ?? unset, monoValue: permission?.mono ?? false
                ) { page = .permissionMode }
            }
            GroupedRow(
                .cpu, title: Text("composer.model", tableName: composer, bundle: .module),
                value: model.modelChoice.map { Text(verbatim: $0.displayName) } ?? unset, monoValue: model.modelChoice != nil
            ) { page = .model }
            let effort = model.reasoningEffort.map(reasoningEffortText)
            GroupedRow(
                .brain, title: Text("composer.effort", tableName: composer, bundle: .module),
                value: effort?.text ?? unset, monoValue: effort?.mono ?? false
            ) { page = .effort }
        }
    }

    private var unset: Text { Text("newconv.tool.unset", tableName: table, bundle: .module) }

    // MARK: 选项页

    @ViewBuilder private var permissionPage: some View {
        back("composer.permissionMode")
        GroupedSection(style: .sheet) {
            SelectionRow(selected: model.permissionMode == nil) { model.choosePermissionMode(nil) } label: { unsetLabel }
            ForEach(model.toolOptions?.permissionModes ?? [], id: \.self) { mode in
                SelectionRow(selected: model.permissionMode == mode) { model.choosePermissionMode(mode) } label: {
                    optionLabel(permissionModeText(mode), raw: mode)
                }
            }
        }
    }

    @ViewBuilder private var modelPage: some View {
        back("composer.model")
        GroupedSection(style: .sheet) {
            SelectionRow(selected: model.modelChoice == nil) { model.chooseModel(nil) } label: { unsetLabel }
            ForEach(model.toolOptions?.models ?? [], id: \.self) { choice in
                SelectionRow(selected: model.modelChoice == choice) { model.chooseModel(choice) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: choice.displayName).font(.agentre(.body))
                        // 两家供应商下同名的模型由供应商名区分。
                        Text(verbatim: choice.providerName.isEmpty ? choice.providerKey : choice.providerName)
                            .font(.agentre(.caption))
                            .foregroundStyle(.token(.ink2))
                    }
                }
            }
        }
    }

    @ViewBuilder private var effortPage: some View {
        back("composer.effort")
        GroupedSection(style: .sheet) {
            SelectionRow(selected: model.reasoningEffort == nil) { model.chooseReasoningEffort(nil) } label: { unsetLabel }
            ForEach(ComposerSettings.reasoningEffortLevels, id: \.self) { level in
                SelectionRow(selected: model.reasoningEffort == level) { model.chooseReasoningEffort(level) } label: {
                    optionLabel(reasoningEffortText(level), raw: level)
                }
            }
        }
    }

    private var unsetLabel: some View {
        unset.font(.agentre(.body))
    }

    /// 表内的档位是人话，下面等宽小字是原值；表外的原样等宽（与对话屏的面板同形）。
    @ViewBuilder private func optionLabel(_ display: (text: Text, mono: Bool), raw: String) -> some View {
        if display.mono {
            display.text.font(.agentre(.body, mono: true))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                display.text.font(.agentre(.body))
                Text(verbatim: raw).font(.agentre(.caption, mono: true)).foregroundStyle(.token(.ink2))
            }
        }
    }

    private func back(_ title: LocalizedStringKey) -> some View {
        Button {
            page = .root
        } label: {
            HStack(spacing: 6) {
                Image(.chevronLeft)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .accessibilityLabel(Text("composer.back", tableName: composer, bundle: .module))
                Text(title, tableName: composer, bundle: .module).font(.agentre(.headline))
            }
            .foregroundStyle(.token(.ink))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .hitTarget()
    }

    // MARK: 人话取值（与对话屏的更多面板同一张表、同一份译文）

    private func permissionModeText(_ mode: String) -> (text: Text, mono: Bool) {
        switch PermissionModeDisplay(mode) {
        case .standard(.`default`): (Text("composer.permissionMode.default", tableName: composer, bundle: .module), false)
        case .standard(.acceptEdits): (Text("composer.permissionMode.acceptEdits", tableName: composer, bundle: .module), false)
        case .standard(.plan): (Text("composer.permissionMode.plan", tableName: composer, bundle: .module), false)
        case .standard(.bypassPermissions): (Text("composer.permissionMode.bypassPermissions", tableName: composer, bundle: .module), false)
        case .raw(let value): (Text(verbatim: value), true)
        }
    }

    private func reasoningEffortText(_ effort: String) -> (text: Text, mono: Bool) {
        switch ReasoningEffortDisplay(effort) {
        case .standard(.low): (Text("composer.effort.low", tableName: composer, bundle: .module), false)
        case .standard(.medium): (Text("composer.effort.medium", tableName: composer, bundle: .module), false)
        case .standard(.high): (Text("composer.effort.high", tableName: composer, bundle: .module), false)
        case .raw(let value): (Text(verbatim: value), true)
        }
    }
}

/// 选项页的一行：当前值打勾。外层由 `GroupedSection` 给背景、圆角与分隔线。
private struct SelectionRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                label.foregroundStyle(.token(.ink))
                Spacer(minLength: 8)
                if selected {
                    Image(.check)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.token(.primary))
                }
            }
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
            .frame(maxWidth: .infinity)
        }
        .hitTarget()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
