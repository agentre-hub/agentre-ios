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
                let permission = model.permissionMode.map(SettingCopy.permissionMode)
                GroupedRow(
                    .shieldCheck, title: Text("composer.permissionMode", tableName: composer, bundle: .module),
                    value: permission?.text ?? unset, monoValue: permission?.mono ?? false
                ) { page = .permissionMode }
            }
            GroupedRow(
                .cpu, title: Text("composer.model", tableName: composer, bundle: .module),
                value: model.modelChoice.map { Text(verbatim: $0.displayName) } ?? unset, monoValue: model.modelChoice != nil
            ) { page = .model }
            let effort = model.reasoningEffort.map(SettingCopy.reasoningEffort)
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
            SettingSelectionRow(selected: model.permissionMode == nil) { model.choosePermissionMode(nil) } label: { unsetLabel }
            ForEach(model.toolOptions?.permissionModes ?? [], id: \.self) { mode in
                SettingSelectionRow(selected: model.permissionMode == mode) { model.choosePermissionMode(mode) } label: {
                    SettingOptionLabel(display: SettingCopy.permissionMode(mode), raw: mode)
                }
            }
        }
    }

    @ViewBuilder private var modelPage: some View {
        back("composer.model")
        GroupedSection(style: .sheet) {
            SettingSelectionRow(selected: model.modelChoice == nil) { model.chooseModel(nil) } label: { unsetLabel }
            ForEach(model.toolOptions?.models ?? [], id: \.self) { choice in
                SettingSelectionRow(selected: model.modelChoice == choice) { model.chooseModel(choice) } label: {
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
            SettingSelectionRow(selected: model.reasoningEffort == nil) { model.chooseReasoningEffort(nil) } label: { unsetLabel }
            ForEach(ComposerSettings.reasoningEffortLevels, id: \.self) { level in
                SettingSelectionRow(selected: model.reasoningEffort == level) { model.chooseReasoningEffort(level) } label: {
                    SettingOptionLabel(display: SettingCopy.reasoningEffort(level), raw: level)
                }
            }
        }
    }

    private var unsetLabel: some View {
        unset.font(.agentre(.body))
    }

    private func back(_ title: LocalizedStringKey) -> some View {
        SettingsPageBack(title: title) { page = .root }
    }
}
