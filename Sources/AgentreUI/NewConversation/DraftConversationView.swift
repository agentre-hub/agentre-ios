import AgentreDesign
import AgentreDomain
import SwiftUI

private let table = "NewConversation"

/// 草稿对话：转录区为空，输入区上方常驻机器与项目两枚 chip，各自点开一个底部面板。
/// 发出第一条消息后 chip 行退场。
public struct DraftConversationView: View {
    @Bindable private var model: DraftConversationModel
    private let onStarted: (ConversationKey) -> Void
    @State private var panel: Panel?
    @Environment(\.isOffline) private var isOffline

    enum Panel: Identifiable {
        case machine
        case project
        var id: Self { self }
    }

    /// - Parameter onStarted: 对话已跑起来并入列，进入它的转录。导航归宿主。
    public init(model: DraftConversationModel, onStarted: @escaping (ConversationKey) -> Void) {
        self.model = model
        self.onStarted = onStarted
    }

    public var body: some View {
        VStack(spacing: 0) {
            transcript
            if model.showsChips {
                chips
                composer
            }
        }
        .background(.token(.bg))
        // 选中的是哪个 Agent 由导航栏说，中央不再写一遍。
        .navigationTitle(Text(verbatim: model.agent.name))
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.plan == nil { await model.loadPlan() } }
        .onChange(of: model.phase, initial: true) { _, phase in
            if case .started(let key) = phase { onStarted(key) }
        }
        .sheet(item: $panel) { panel in
            switch panel {
            case .machine: NewConversationMachinePanel(model: model).presentationDetents([.medium, .large])
            case .project: NewConversationProjectPanel(model: model).presentationDetents([.medium, .large])
            }
        }
    }

    private var transcript: some View {
        List {
            if let sent = model.sentText {
                HStack {
                    Spacer(minLength: 48)
                    Text(verbatim: sent)
                        .foregroundStyle(.token(.textPrimary))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.token(.surface2), in: RoundedRectangle(cornerRadius: 16))
                }
                .row()
            }
            switch model.phase {
            case .notListed(let started):
                VStack(alignment: .leading, spacing: 8) {
                    Text("newconv.notListed \(Text(verbatim: started.machineName).font(.subheadline.monospaced()))", tableName: table, bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.token(.waiting))
                    Button {
                        Task { await model.retryRecording() }
                    } label: {
                        Text("newconv.retry", tableName: table, bundle: .module)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.token(.accent))
                    }
                    .hitTarget()
                }
                .row()
            case .dispatchFailed(let failure, let machine):
                failureText(failure, machine: machine)
                    .font(.subheadline)
                    .foregroundStyle(.token(.failure))
                    .row()
            case .draft, .sending, .started:
                EmptyView()
            }
            if isOffline, model.showsChips {
                Label {
                    Text("newconv.deviceOffline", tableName: table, bundle: .module)
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .font(.subheadline)
                .foregroundStyle(.token(.textSecondary))
                .row()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func failureText(_ failure: DispatchFailure, machine: String) -> Text {
        let name = Text(verbatim: machine).font(.subheadline.monospaced())
        switch failure {
        case .unreachable: return Text("newconv.connectFailed \(name)", tableName: table, bundle: .module)
        case .rejected: return Text("newconv.startFailed \(name)", tableName: table, bundle: .module)
        case .updateRequired: return Text(LocalizedStringKey(failureKey(.updateRequired)), tableName: "Me", bundle: .module)
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            Chip(systemImage: "desktopcomputer") {
                if model.machineChip == .planFailed {
                    Task { await model.loadPlan() }
                } else {
                    panel = .machine
                }
            } label: { machineLabel }
            Chip(systemImage: "folder") { panel = .project } label: {
                if let project = model.project {
                    Text(verbatim: project.name)
                } else {
                    Text("newconv.noProject", tableName: table, bundle: .module)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var machineLabel: some View {
        switch model.machineChip {
        case .resolving: ProgressView()
        case .machine(let name): Text(verbatim: name).monospaced()
        case .unavailable(let reason): NewConversationReasonText(availability: reason).foregroundStyle(.token(.failure))
        case .noTarget: Text("newconv.noAvailableTarget", tableName: table, bundle: .module).foregroundStyle(.token(.failure))
        case .planFailed: Text("newconv.planFailed", tableName: table, bundle: .module).foregroundStyle(.token(.failure))
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            NewConversationComposerField(text: $model.text, placeholder: LocalizedCopy("newconv.message", table: table))
                .overlay(alignment: .leading) {
                    if model.text.isEmpty {
                        Text("newconv.message", tableName: table, bundle: .module)
                            .foregroundStyle(.token(.textSecondary))
                            .padding(.leading, 13)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .background(.token(.surface), in: RoundedRectangle(cornerRadius: 22))
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(.token(model.canSend && !isOffline ? .accent : .textSecondary))
                    .accessibilityLabel(Text("newconv.send", tableName: table, bundle: .module))
            }
            .hitTarget()
            .disabled(!model.canSend || isOffline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 输入区上方的一枚 chip：绘制 32pt 高，命中区由 `hitTarget()` 补满 44。
private struct Chip<Content: View>: View {
    let systemImage: String
    let action: () -> Void
    @ViewBuilder let label: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                label.lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.footnote)
            .foregroundStyle(.token(.textPrimary))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.token(.surface2), in: Capsule())
        }
        .hitTarget()
    }
}

private extension View {
    func row() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}

// MARK: 面板

/// 机器面板：该 Agent 的执行目标链逐档列出次序号、机器名、后端种类；不可用的档列出但压暗并写明原因。
/// 手动指定后底部出现交回自动挑。覆盖只对这一次对话生效。
public struct NewConversationMachinePanel: View {
    private let model: DraftConversationModel
    @Environment(\.dismiss) private var dismiss

    public init(model: DraftConversationModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("newconv.pickTargetTitle", tableName: table, bundle: .module)
                .font(.headline)
                .foregroundStyle(.token(.textPrimary))
                .padding(16)
            List {
                ForEach(model.plan?.tiers ?? []) { tier in
                    if tier.availability.isAvailable {
                        Button {
                            Task {
                                await model.pick(tier)
                                dismiss()
                            }
                        } label: {
                            TierRow(tier: tier, chosen: model.plan?.chosen?.backendSyncID == tier.backendSyncID)
                        }
                        .hitTarget()
                        .row()
                    } else {
                        TierRow(tier: tier, chosen: false)
                            .opacity(0.45)
                            .row()
                    }
                }
                if model.manualTarget != nil {
                    Button {
                        Task {
                            await model.useAutomatic()
                            dismiss()
                        }
                    } label: {
                        Text("newconv.useAutoTarget", tableName: table, bundle: .module)
                            .foregroundStyle(.token(.accent))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .hitTarget()
                    .row()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(.token(.surface))
    }
}

private struct TierRow: View {
    let tier: DispatchTier
    let chosen: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: String(tier.rank))
                .font(.subheadline.monospaced())
                .foregroundStyle(.token(.textSecondary))
                .frame(minWidth: 16)
            VStack(alignment: .leading, spacing: 2) {
                if !tier.deviceName.isEmpty {
                    Text(verbatim: tier.deviceName)
                        .font(.body.monospaced())
                        .foregroundStyle(.token(.textPrimary))
                }
                if !tier.backendType.isEmpty {
                    Text(verbatim: tier.backendType)
                        .font(.caption.monospaced())
                        .foregroundStyle(.token(.textSecondary))
                }
            }
            Spacer(minLength: 8)
            if !tier.availability.isAvailable {
                NewConversationReasonText(availability: tier.availability)
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
            }
            if chosen {
                Image(systemName: "checkmark")
                    .foregroundStyle(.token(.accent))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 项目面板：不指定项目，或选一个项目（决定工作目录）。
public struct NewConversationProjectPanel: View {
    private let model: DraftConversationModel
    @Environment(\.dismiss) private var dismiss

    public init(model: DraftConversationModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("newconv.pickProjectTitle", tableName: table, bundle: .module)
                .font(.headline)
                .foregroundStyle(.token(.textPrimary))
                .padding(16)
            List {
                option(nil, depth: 0) {
                    Text("newconv.noProject", tableName: table, bundle: .module)
                }
                ForEach(WorkspaceProjectRow.flatten(model.projects)) { row in
                    option(row.project, depth: row.depth) {
                        Text(verbatim: row.project.name)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(.token(.surface))
    }

    private func option(_ project: WorkspaceProject?, depth: Int, @ViewBuilder label: () -> some View) -> some View {
        Button {
            Task {
                await model.choose(project)
                dismiss()
            }
        } label: {
            HStack {
                label().foregroundStyle(.token(.textPrimary))
                Spacer()
                if model.project?.syncID == project?.syncID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.token(.accent))
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, CGFloat(depth) * 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .hitTarget()
        .row()
    }
}
