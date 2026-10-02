import AgentreDesign
import AgentreDomain
import SwiftUI

private let table = "NewConversation"

/// 草稿对话：导航栏是 Agent 字形、标题「新对话」、副标题 Agent 名；转录区为空，输入区上方常驻机器与
/// 项目两枚 chip，各自点开一个底部面板；输入框下是与对话屏同一形态的工具行（没有上下文环）。
/// 发出第一条消息后 chip 行、输入区与工具行一起退场。
public struct DraftConversationView: View {
    @Bindable private var model: DraftConversationModel
    private let onStarted: (ConversationKey) -> Void
    @State private var panel: Panel?
    @Environment(\.isOffline) private var isOffline

    enum Panel: Hashable, Identifiable {
        case machine
        case project
        case tool(DraftToolPanel.Page)
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
                composer
            }
        }
        .background(.token(.bg))
        .compactNavigationBar(
            title: Text("newconv.title", tableName: table, bundle: .module),
            subtitle: Text(verbatim: model.agent.name),
            leading: { AvatarGlyph(.agent(model.agent), size: 34) }
        )
        .task { if model.plan == nil { await model.loadPlan() } }
        .onChange(of: model.phase, initial: true) { _, phase in
            if case .started(let key) = phase { onStarted(key) }
        }
        .fittedSheet(item: $panel) { panel in
            switch panel {
            case .machine: NewConversationMachinePanel(model: model)
            case .tool(let page): DraftToolPanel(model: model, initialPage: page)
            case .project: NewConversationProjectPanel(model: model)
            }
        }
    }

    private var transcript: some View {
        List {
            if let sent = model.sentText {
                // 与对话屏同一枚用户气泡（规格「02」）：这条对话发出去后就是那一屏的第一条。
                UserBubble(text: sent)
                    .row()
            }
            switch model.phase {
            case .notListed(let started):
                VStack(alignment: .leading, spacing: 8) {
                    Text("newconv.notListed \(Text(verbatim: started.machineName).font(.agentre(.subheadline, mono: true)))", tableName: table, bundle: .module)
                        .font(.agentre(.subheadline))
                        .foregroundStyle(.token(.amber))
                    Button {
                        Task { await model.retryRecording() }
                    } label: {
                        Text("newconv.retry", tableName: table, bundle: .module)
                            .font(.agentre(.subheadline, weight: .semibold))
                            .foregroundStyle(.token(.primary))
                    }
                    .hitTarget()
                }
                .row()
            case .dispatchFailed(let failure, let machine):
                failureText(failure, machine: machine)
                    .font(.agentre(.subheadline))
                    .foregroundStyle(.token(.coral))
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
                .font(.agentre(.subheadline))
                .foregroundStyle(.token(.ink2))
                .row()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func failureText(_ failure: DispatchFailure, machine: String) -> Text {
        let name = Text(verbatim: machine).font(.agentre(.subheadline, mono: true))
        switch failure {
        case .unreachable: return Text("newconv.connectFailed \(name)", tableName: table, bundle: .module)
        case .rejected: return Text("newconv.startFailed \(name)", tableName: table, bundle: .module)
        case .updateRequired: return Text(LocalizedStringKey(failureKey(.updateRequired)), tableName: "Me", bundle: .module)
        }
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            chips
            inputRow
            toolRow
        }
        .padding(EdgeInsets(top: 9, leading: 14, bottom: 12, trailing: 14))
        .background(.token(.bg))
        .overlay(alignment: .top) { Rectangle().fill(.token(.line)).frame(height: 1) }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            Chip(icon: .monitor, iconToken: machineOnline ? .run : .ink3) {
                if model.machineChip == .planFailed {
                    Task { await model.loadPlan() }
                } else {
                    panel = .machine
                }
            } label: { machineLabel }
            Chip(icon: .folder, iconToken: .ink3) { panel = .project } label: {
                Group {
                    if let project = model.project {
                        Text(verbatim: project.name)
                    } else {
                        Text("newconv.noProject", tableName: table, bundle: .module)
                    }
                }
                .font(.agentre(.footnote, weight: .semibold))
                .foregroundStyle(.token(.ink2))
            }
            Spacer(minLength: 0)
        }
    }

    private var machineOnline: Bool {
        if case .machine = model.machineChip { true } else { false }
    }

    /// 机器 chip：机器名与等宽后端种类；跑不了时写具体原因（次级文字色，不可用不是失败），没问到才是红。
    @ViewBuilder private var machineLabel: some View {
        switch model.machineChip {
        case .resolving:
            ProgressView().controlSize(.mini)
        case .machine(let name):
            HStack(spacing: 6) {
                Text(verbatim: name)
                    .font(.agentre(.footnote, mono: true, weight: .semibold))
                    .foregroundStyle(.token(.ink2))
                if let backend = model.plan?.chosen?.backendType, !backend.isEmpty {
                    Text(verbatim: backend)
                        .font(.agentre(FontRole(size: 10, relativeTo: .caption2), mono: true))
                        .foregroundStyle(.token(.ink3))
                }
            }
        case .unavailable(let reason):
            NewConversationReasonText(availability: reason)
                .font(.agentre(.footnote, weight: .semibold))
                .foregroundStyle(.token(.ink2))
        case .noTarget:
            Text("newconv.noAvailableTarget", tableName: table, bundle: .module)
                .font(.agentre(.footnote, weight: .semibold))
                .foregroundStyle(.token(.ink2))
        case .planFailed:
            Text("newconv.planFailed", tableName: table, bundle: .module)
                .font(.agentre(.footnote, weight: .semibold))
                .foregroundStyle(.token(.coral))
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 9) {
            NewConversationComposerField(text: $model.text, placeholder: LocalizedCopy("newconv.message", table: table))
                .overlay(alignment: .leading) {
                    if model.text.isEmpty {
                        Text("newconv.message", tableName: table, bundle: .module)
                            .font(.agentre(FontRole(size: 14.5, relativeTo: .body)))
                            .foregroundStyle(.token(.ink3))
                            .padding(.leading, 14)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .background(.token(.surface), in: Capsule())
                .overlay(Capsule().strokeBorder(.token(.line)))
            Button {
                Task { await model.send() }
            } label: {
                let canSend = model.canSend && !isOffline
                Image(.arrowUp)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.token(canSend ? .primaryInk : .ink2))
                    .padding(10)
                    .background(.token(canSend ? .primary : .surface2), in: Circle())
                    .accessibilityLabel(Text("newconv.send", tableName: table, bundle: .module))
            }
            .hitTarget()
            .disabled(!model.canSend || isOffline)
        }
    }

    /// 与对话屏同一形态的工具行：`+`（面板）实心，其余三项只用图标；Pi 后端没有权限模式这一枚。
    private var toolRow: some View {
        HStack(spacing: 2) {
            toolButton(.plus, "composer.more", page: .root, filled: true)
            if model.offersPermissionMode {
                toolButton(.shieldCheck, "composer.permissionMode", page: .permissionMode)
            }
            toolButton(.cpu, "composer.model", page: .model)
            toolButton(.brain, "composer.effort", page: .effort)
            Spacer(minLength: 0)
        }
    }

    private func toolButton(_ icon: AgentreIcon, _ label: LocalizedStringKey, page: DraftToolPanel.Page, filled: Bool = false) -> some View {
        Button {
            panel = .tool(page)
        } label: {
            Image(icon)
                .resizable()
                .frame(width: 20, height: 20)
                .foregroundStyle(.token(filled ? .ink : .ink2))
                .padding(8)
                .background(filled ? .token(.surface2) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(Text(label, tableName: "Composer", bundle: .module))
        }
        .hitTarget()
    }
}

/// 输入区上方的一枚 chip：`surface` 圆角描边，绘制 30pt 高，命中区由 `hitTarget()` 补满 44。
private struct Chip<Content: View>: View {
    let icon: AgentreIcon
    let iconToken: ColorToken
    let action: () -> Void
    @ViewBuilder let label: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(icon)
                    .resizable()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(.token(iconToken))
                    .accessibilityHidden(true)
                label.lineLimit(1)
                Image(.chevronDown)
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.token(.ink3))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.token(.surface), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.token(.line)))
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

// MARK: 05D 选执行机器

/// 机器面板「在哪台机器上跑」：该 Agent 的执行目标链排在一张分组卡片里，逐档写等宽次序号、机器名、
/// 等宽后端种类，选中的打勾；不可用的档列出但压暗并写明原因。手动指定后底部出现「交回自动挑」。
/// 覆盖只对这一次对话生效。
public struct NewConversationMachinePanel: View {
    private let model: DraftConversationModel
    @Environment(\.dismiss) private var dismiss

    public init(model: DraftConversationModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("newconv.pickTargetTitle", tableName: table, bundle: .module)
                .font(.agentre(.headline))
                .foregroundStyle(.token(.ink))
                .padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)
            GroupedSection(style: .sheet) {
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
                    } else {
                        TierRow(tier: tier, chosen: false)
                            .opacity(0.45)
                    }
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
                        .font(.agentre(FontRole(size: 14.5, relativeTo: .body)))
                        .foregroundStyle(.token(.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                .hitTarget()
            }
        }
    }
}

private struct TierRow: View {
    let tier: DispatchTier
    let chosen: Bool

    var body: some View {
        HStack(spacing: 11) {
            Text(verbatim: String(tier.rank))
                .font(.agentre(FontRole(size: 11, relativeTo: .caption), mono: true))
                .foregroundStyle(.token(.ink3))
            Group {
                if tier.deviceName.isEmpty {
                    Text("newconv.noDevice", tableName: table, bundle: .module)
                        .font(.agentre(FontRole(size: 14.5, relativeTo: .body)))
                } else {
                    Text(verbatim: tier.deviceName)
                        .font(.agentre(FontRole(size: 14.5, relativeTo: .body), mono: true))
                }
            }
            .foregroundStyle(.token(.ink))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !tier.backendType.isEmpty {
                Text(verbatim: tier.backendType)
                    .font(.agentre(FontRole(size: 11, relativeTo: .caption), mono: true))
                    .foregroundStyle(.token(.ink3))
            }
            if !tier.availability.isAvailable {
                NewConversationReasonText(availability: tier.availability)
                    .font(.agentre(.footnote))
                    .foregroundStyle(.token(.ink2))
            }
            if chosen {
                Image(.check)
                    .resizable()
                    .frame(width: 17, height: 17)
                    .foregroundStyle(.token(.primary))
                    .accessibilityHidden(true)
            }
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

// MARK: 项目面板

/// 项目面板：不指定项目，或选一个项目（决定工作目录）。与其余面板同一形态：标题下一张分组卡片，
/// 子项目按层级缩进；项目树很长时面板封顶在全屏档、在里面滚动（`fittedSheet`）。
public struct NewConversationProjectPanel: View {
    private let model: DraftConversationModel
    @Environment(\.dismiss) private var dismiss

    public init(model: DraftConversationModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("newconv.pickProjectTitle", tableName: table, bundle: .module)
                .font(.agentre(.headline))
                .foregroundStyle(.token(.ink))
                .padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)
            GroupedSection(style: .sheet) {
                option(nil, depth: 0) {
                    Text("newconv.noProject", tableName: table, bundle: .module)
                }
                ForEach(WorkspaceProjectRow.flatten(model.projects)) { row in
                    option(row.project, depth: row.depth) {
                        Text(verbatim: row.project.name)
                    }
                }
            }
        }
    }

    private func option(_ project: WorkspaceProject?, depth: Int, @ViewBuilder label: () -> some View) -> some View {
        Button {
            Task {
                await model.choose(project)
                dismiss()
            }
        } label: {
            HStack(spacing: 11) {
                Image(.folder)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .foregroundStyle(.token(.ink3))
                    .accessibilityHidden(true)
                label()
                    .font(.agentre(FontRole(size: 14.5, relativeTo: .body)))
                    .foregroundStyle(.token(.ink))
                Spacer()
                if model.project?.syncID == project?.syncID {
                    Image(.check)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.token(.primary))
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, CGFloat(depth) * 20)
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .hitTarget()
    }
}
