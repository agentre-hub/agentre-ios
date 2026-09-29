import AgentreDesign
import AgentreDomain
import SwiftUI

/// 更多面板：两组分组卡片——权限模式、模型、思考档位一组；会话信息、上下文、删除会话一组
/// （规格「逐屏视觉契约·04 更多面板」）。常驻行上的三枚图标直接打开对应的那一页。
public struct ComposerPanel: View {
    public enum Page: Hashable, Identifiable {
        case root, permissionMode, model, effort, sessionInfo, context
        public var id: Self { self }
    }

    private let model: ComposerModel
    private let contextUsage: ContextUsage?
    private let onDeleted: () -> Void
    @State private var page: Page
    @State private var confirmsDelete = false
    @Environment(\.isOffline) private var isOffline
    @Environment(\.dismiss) private var dismiss

    public init(model: ComposerModel, contextUsage: ContextUsage?, initialPage: Page = .root, onDeleted: @escaping () -> Void) {
        self.model = model
        self.contextUsage = contextUsage
        self.onDeleted = onDeleted
        _page = State(initialValue: initialPage)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch page {
            case .root: root
            case .permissionMode: permissionPage
            case .model: modelPage
            case .effort: effortPage
            case .sessionInfo: infoPage
            case .context: contextPage
            }
            if isOffline {
                ComposerOfflineText()
            } else if let failure = model.failure {
                ComposerFailureText(failure: failure)
            }
        }
        .confirmationDialog(Text("composer.delete", tableName: composerTable, bundle: .module), isPresented: $confirmsDelete) {
            Button(role: .destructive) {
                Task {
                    guard await model.deleteConversation() else { return }
                    dismiss()
                    onDeleted()
                }
            } label: {
                Text("composer.deleteConfirm", tableName: composerTable, bundle: .module)
            }
        }
    }

    // MARK: 根

    @ViewBuilder private var root: some View {
        let settings = model.settings
        GroupedSection(style: .sheet) {
            let permission = settings.map { permissionModeText($0.permissionMode) }
            GroupedRow(
                .shieldCheck, title: Text("composer.permissionMode", tableName: composerTable, bundle: .module),
                value: permission?.text, monoValue: permission?.mono ?? false
            ) { page = .permissionMode }
            GroupedRow(
                .cpu, title: Text("composer.model", tableName: composerTable, bundle: .module),
                value: settings?.model.map { Text(verbatim: $0.displayName) }, monoValue: true
            ) { page = .model }
            let effort = reasoningEffortText(settings?.reasoningEffort ?? "")
            GroupedRow(
                .brain, title: Text("composer.effort", tableName: composerTable, bundle: .module),
                value: effort.text, monoValue: effort.mono
            ) { page = .effort }
        }
        GroupedSection(style: .sheet) {
            GroupedRow(
                .info, title: Text("composer.sessionInfo", tableName: composerTable, bundle: .module),
                value: model.machineName.map { Text(verbatim: $0) }
            ) { page = .sessionInfo }
            GroupedRow(
                .gauge, title: Text("composer.context", tableName: composerTable, bundle: .module),
                value: contextUsage.map { Text(verbatim: $0.compactSummary) }, monoValue: true
            ) { page = .context }
            GroupedRow(.trash2, title: Text("composer.delete", tableName: composerTable, bundle: .module), role: .destructive) {
                confirmsDelete = true
            }
            .disabled(isOffline)
        }
    }

    // MARK: 三项

    @ViewBuilder private var permissionPage: some View {
        back("composer.permissionMode")
        let current = model.settings?.permissionMode
        GroupedSection(style: .sheet) {
            ForEach(model.settings?.permissionModes ?? [], id: \.self) { mode in
                let display = permissionModeText(mode)
                ComposerSelectionRow(selected: mode == current) {
                    Task { await model.setPermissionMode(mode) }
                } label: {
                    if display.mono {
                        display.text.font(.agentre(.body, mono: true))
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            display.text.font(.agentre(.body))
                            Text(verbatim: mode).font(.agentre(.caption, mono: true)).foregroundStyle(.token(.ink2))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var modelPage: some View {
        back("composer.model")
        let current = model.settings?.model
        // 与宿主 model-target-picker 同：按供应商分组、组头是供应商名，行是可读名、副行是模型 ID——
        // 两家供应商下同名的模型由组头区分。
        ForEach(Self.providerGroups(model.settings?.models ?? []), id: \.providerKey) { group in
            Text(verbatim: group.title)
                .font(.agentre(.footnote))
                .foregroundStyle(.token(.ink2))
            GroupedSection(style: .sheet) {
                ForEach(group.models, id: \.self) { choice in
                    ComposerSelectionRow(selected: choice == current) {
                        Task { await model.setModel(choice) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: choice.displayName).font(.agentre(.body))
                            if !choice.modelId.isEmpty, choice.modelId != choice.displayName {
                                Text(verbatim: choice.modelId)
                                    .font(.agentre(.caption, mono: true))
                                    .foregroundStyle(.token(.ink2))
                            }
                        }
                    }
                }
            }
        }
    }

    /// 目录次序里按供应商归组（目录本就按供应商连续排列；保持首次出现的次序）。
    private static func providerGroups(_ models: [ComposerModelChoice]) -> [(providerKey: String, title: String, models: [ComposerModelChoice])] {
        var groups: [(providerKey: String, title: String, models: [ComposerModelChoice])] = []
        for choice in models {
            if let index = groups.firstIndex(where: { $0.providerKey == choice.providerKey }) {
                groups[index].models.append(choice)
            } else {
                groups.append((choice.providerKey, choice.providerName.isEmpty ? choice.providerKey : choice.providerName, [choice]))
            }
        }
        return groups
    }

    @ViewBuilder private var effortPage: some View {
        back("composer.effort")
        let current = model.settings?.reasoningEffort
        GroupedSection(style: .sheet) {
            ForEach([""] + ComposerSettings.reasoningEffortLevels, id: \.self) { level in
                ComposerSelectionRow(selected: level == current) {
                    Task { await model.setReasoningEffort(level) }
                } label: {
                    if level.isEmpty {
                        Text("composer.effort.followBackend", tableName: composerTable, bundle: .module).font(.agentre(.body))
                    } else {
                        let display = reasoningEffortText(level)
                        if display.mono {
                            display.text.font(.agentre(.body, mono: true))
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                display.text.font(.agentre(.body))
                                Text(verbatim: level).font(.agentre(.caption, mono: true)).foregroundStyle(.token(.ink2))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 会话信息与上下文

    @ViewBuilder private var infoPage: some View {
        back("composer.sessionInfo")
        let conversation = model.conversation
        GroupedSection(style: .sheet) {
            ComposerFactRow("composer.info.title", Text(verbatim: conversation.title))
            ComposerFactRow("composer.info.machine", Text(verbatim: conversation.carrierFingerprint).monospaced())
            ComposerFactRow("composer.info.cwd", Text(verbatim: conversation.cwd).monospaced())
            ComposerFactRow("composer.info.backend", Text(verbatim: conversation.backendType).monospaced())
            ComposerFactRow("composer.info.id", Text(verbatim: conversation.key.conversationID).monospaced())
        }
    }

    @ViewBuilder private var contextPage: some View {
        back("composer.context")
        if let contextUsage {
            GroupedSection(style: .sheet) { ContextUsageDetail(usage: contextUsage) }
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
                    .accessibilityLabel(Text("composer.back", tableName: composerTable, bundle: .module))
                Text(title, tableName: composerTable, bundle: .module).font(.agentre(.headline))
            }
            .foregroundStyle(.token(.ink))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .hitTarget()
    }

    // MARK: 人话取值

    /// 权限档位人话：表内已知档位取本地化名（非等宽），表外原样等宽（规格「04 更多面板」）。
    private func permissionModeText(_ mode: String) -> (text: Text, mono: Bool) {
        switch PermissionModeDisplay(mode) {
        case .standard(.`default`): (Text("composer.permissionMode.default", tableName: composerTable, bundle: .module), false)
        case .standard(.acceptEdits): (Text("composer.permissionMode.acceptEdits", tableName: composerTable, bundle: .module), false)
        case .standard(.plan): (Text("composer.permissionMode.plan", tableName: composerTable, bundle: .module), false)
        case .standard(.bypassPermissions): (Text("composer.permissionMode.bypassPermissions", tableName: composerTable, bundle: .module), false)
        case .raw(let value): (Text(verbatim: value), true)
        }
    }

    /// 思考档位人话：低/中/高非等宽，会话未设定时标「默认」，执行端报出的更高档原样等宽。
    private func reasoningEffortText(_ effort: String) -> (text: Text, mono: Bool) {
        guard !effort.isEmpty else { return (Text("composer.effort.default", tableName: composerTable, bundle: .module), false) }
        switch ReasoningEffortDisplay(effort) {
        case .standard(.low): return (Text("composer.effort.low", tableName: composerTable, bundle: .module), false)
        case .standard(.medium): return (Text("composer.effort.medium", tableName: composerTable, bundle: .module), false)
        case .standard(.high): return (Text("composer.effort.high", tableName: composerTable, bundle: .module), false)
        case .raw(let value): return (Text(verbatim: value), true)
        }
    }
}

/// 选项页的一行：当前值打勾。外层由 `GroupedSection` 给背景、圆角与分隔线。
private struct ComposerSelectionRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.isOffline) private var isOffline

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
        .disabled(isOffline)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 会话信息的一行事实：名称在左，值在右（机器产出的等宽）。
private struct ComposerFactRow: View {
    let title: LocalizedStringKey
    let value: Text

    init(_ title: LocalizedStringKey, _ value: Text) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title, tableName: composerTable, bundle: .module)
                .foregroundStyle(.token(.ink2))
            Spacer(minLength: 8)
            value
                .foregroundStyle(.token(.ink))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.agentre(.subheadline))
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
    }
}
