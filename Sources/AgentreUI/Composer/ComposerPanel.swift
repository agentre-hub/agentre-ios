import AgentreDesign
import AgentreDomain
import SwiftUI

/// 更多面板：权限模式、模型、思考档位逐行标注当前取值，另有会话信息、上下文与删除会话。
/// 常驻行上的三枚图标直接打开对应的那一页。
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
    @Environment(\.dismiss) private var dismiss

    public init(model: ComposerModel, contextUsage: ContextUsage?, initialPage: Page = .root, onDeleted: @escaping () -> Void) {
        self.model = model
        self.contextUsage = contextUsage
        self.onDeleted = onDeleted
        _page = State(initialValue: initialPage)
    }

    public var body: some View {
        List {
            switch page {
            case .root: root
            case .permissionMode: permissionPage
            case .model: modelPage
            case .effort: effortPage
            case .sessionInfo: infoPage
            case .context: contextPage
            }
            if let failure = model.failure { ComposerFailureText(failure: failure).composerRow() }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.token(.bg))
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
        ComposerPanelRow("composer.permissionMode") { page = .permissionMode } value: {
            if let mode = settings?.permissionMode, !mode.isEmpty { Text(verbatim: mode).monospaced() }
        }
        ComposerPanelRow("composer.model") { page = .model } value: {
            if let current = settings?.model { Text(verbatim: current.modelKey).monospaced() }
        }
        ComposerPanelRow("composer.effort") { page = .effort } value: {
            if let settings { ComposerEffortLabel(effort: settings.effectiveReasoningEffort) }
        }
        ComposerPanelRow("composer.sessionInfo") { page = .sessionInfo } value: { EmptyView() }
        ComposerPanelRow("composer.context") { page = .context } value: {
            if let contextUsage { Text("composer.contextPercent \(contextUsage.percent)", tableName: composerTable, bundle: .module) }
        }
        Button {
            confirmsDelete = true
        } label: {
            Text("composer.delete", tableName: composerTable, bundle: .module)
                .foregroundStyle(.token(.failure))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .hitTarget()
        .composerRow()
    }

    // MARK: 三项

    @ViewBuilder private var permissionPage: some View {
        back("composer.permissionMode")
        let current = model.settings?.permissionMode
        ForEach(model.settings?.permissionModes ?? [], id: \.self) { mode in
            ComposerOptionRow(selected: mode == current) {
                Task { await model.setPermissionMode(mode) }
            } label: {
                Text(verbatim: mode).monospaced()
            }
        }
    }

    @ViewBuilder private var modelPage: some View {
        back("composer.model")
        let current = model.settings?.model
        ForEach(model.settings?.models ?? [], id: \.self) { choice in
            ComposerOptionRow(selected: choice == current) {
                Task { await model.setModel(choice) }
            } label: {
                Text(verbatim: choice.modelKey).monospaced()
            }
        }
    }

    @ViewBuilder private var effortPage: some View {
        back("composer.effort")
        let current = model.settings?.reasoningEffort
        ForEach([""] + ComposerSettings.reasoningEffortLevels, id: \.self) { level in
            ComposerOptionRow(selected: level == current) {
                Task { await model.setReasoningEffort(level) }
            } label: {
                if level.isEmpty {
                    Text("composer.effort.followBackend", tableName: composerTable, bundle: .module)
                } else {
                    Text(verbatim: level).monospaced()
                }
            }
        }
    }

    // MARK: 会话信息与上下文

    @ViewBuilder private var infoPage: some View {
        back("composer.sessionInfo")
        let conversation = model.conversation
        ComposerFactRow("composer.info.title", Text(verbatim: conversation.title))
        ComposerFactRow("composer.info.machine", Text(verbatim: conversation.key.machineFingerprint).monospaced())
        ComposerFactRow("composer.info.cwd", Text(verbatim: conversation.cwd).monospaced())
        ComposerFactRow("composer.info.backend", Text(verbatim: conversation.backendType).monospaced())
        ComposerFactRow("composer.info.id", Text(verbatim: conversation.key.conversationID).monospaced())
    }

    @ViewBuilder private var contextPage: some View {
        back("composer.context")
        if let contextUsage { ContextUsageDetail(usage: contextUsage).composerRow() }
    }

    private func back(_ title: LocalizedStringKey) -> some View {
        Button {
            page = .root
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .accessibilityLabel(Text("composer.back", tableName: composerTable, bundle: .module))
                Text(title, tableName: composerTable, bundle: .module).font(.headline)
            }
            .foregroundStyle(.token(.textPrimary))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .hitTarget()
        .composerRow()
    }
}

/// 根页的一行：名称在左，当前取值在右。
private struct ComposerPanelRow<Value: View>: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder let value: Value

    init(_ title: LocalizedStringKey, action: @escaping () -> Void, @ViewBuilder value: () -> Value) {
        self.title = title
        self.action = action
        self.value = value()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title, tableName: composerTable, bundle: .module)
                    .foregroundStyle(.token(.textPrimary))
                Spacer(minLength: 8)
                value
                    .font(.subheadline)
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.token(.textSecondary))
            }
            .frame(maxWidth: .infinity)
        }
        .hitTarget()
        .composerRow()
    }
}

/// 选项页的一行：当前值打勾。
private struct ComposerOptionRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack {
                label.foregroundStyle(.token(.textPrimary))
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.token(.accent))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .hitTarget()
        .composerRow()
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
                .foregroundStyle(.token(.textSecondary))
            Spacer(minLength: 8)
            value
                .foregroundStyle(.token(.textPrimary))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .composerRow()
    }
}

/// 思考档位的有效值：空 = 默认（会话与后端都没设定）。
private struct ComposerEffortLabel: View {
    let effort: String

    var body: some View {
        if effort.isEmpty {
            Text("composer.effort.default", tableName: composerTable, bundle: .module)
        } else {
            Text(verbatim: effort).monospaced()
        }
    }
}

private extension View {
    func composerRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}
