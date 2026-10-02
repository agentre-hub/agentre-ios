import AgentreDesign
import AgentreDomain
import SwiftUI

private let table = "NewConversation"

/// 不可用档的原因：取宿主的原话。
struct NewConversationReasonText: View {
    let availability: TargetAvailability

    var body: some View {
        Text(reasonKey(availability), tableName: table, bundle: .module)
    }
}

/// 机器产出的内容（机器名、路径、后端种类）以等宽字体呈现。
private func machineText(_ value: String) -> Text {
    Text(verbatim: value).font(.agentre(.footnote, mono: true))
}

private func reasonKey(_ availability: TargetAvailability) -> LocalizedStringKey {
    switch availability {
    case .offline: "newconv.offline"
    case .unpaired: "newconv.unpaired"
    case .noDevice: "newconv.noDevice"
    case .projectPathMissing: "newconv.projectPathMissing"
    case .available, .unrecognized: "newconv.noAvailableTarget"
    }
}

/// 「当前落到某机器」或跑不了的具体原因。
private func unavailableText(device: String, reason: TargetAvailability) -> Text {
    guard !device.isEmpty else { return Text(reasonKey(reason), tableName: table, bundle: .module) }
    return Text("newconv.unavailableOn \(machineText(device)) \(Text(reasonKey(reason), tableName: table, bundle: .module))", tableName: table, bundle: .module)
}

/// 选 Agent 那一行副行的图标与颜色：落点是 `ink-3` 加服务器图标；跑不了是次级文字色加插头图标——
/// 不可用不是失败，不用红（规格决策 19）。
struct LandingLine: Equatable {
    let icon: AgentreIcon
    let token: ColorToken

    init(icon: AgentreIcon, token: ColorToken) {
        self.icon = icon
        self.token = token
    }

    init(available: Bool) {
        self = available ? LandingLine(icon: .server, token: .ink3) : LandingLine(icon: .plugZap, token: .ink2)
    }
}

/// 选 Agent 的一行：Agent 字形、名字，下面是解析结果——当前落到哪台机器，或跑不了的具体原因。
/// 跑不了的行整行压暗、不可点。
private struct AgentRow<Subtitle: View>: View {
    let agent: WorkspaceAgent
    let available: Bool
    let onPick: () -> Void
    @ViewBuilder let subtitle: Subtitle

    var body: some View {
        let line = LandingLine(available: available)
        Button(action: onPick) {
            HStack(spacing: 12) {
                AvatarGlyph(.agent(agent), size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: agent.name)
                        .font(.agentre(.body, weight: .medium))
                        .foregroundStyle(.token(.ink))
                    HStack(spacing: 5) {
                        Image(line.icon)
                            .resizable()
                            .frame(width: 11, height: 11)
                            .accessibilityHidden(true)
                        subtitle
                            .font(.agentre(.footnote))
                            .lineLimit(2)
                    }
                    .foregroundStyle(.token(line.token))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if available {
                    Image(.chevronRight)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.token(.ink3))
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 2)
        }
        .hitTarget()
        .disabled(!available)
        .opacity(available ? 1 : 0.55)
    }
}

/// 入口与「最近用过」的一行：解析结果取自 Agent 清单（账号默认次序，不看项目）。
private struct SummaryAgentRow: View {
    let agent: WorkspaceAgent
    let onPick: (WorkspaceAgent) -> Void

    var body: some View {
        AgentRow(agent: agent, available: agent.hasAvailableTarget, onPick: { onPick(agent) }) {
            switch agent.targetSummary {
            case .landsOn(let device):
                Text("newconv.currentTarget \(machineText(device))", tableName: table, bundle: .module)
            case .landsOnThisDevice:
                Text("newconv.currentTarget \(Text("newconv.thisDevice", tableName: table, bundle: .module))", tableName: table, bundle: .module)
            case .unavailable(let device, let reason):
                unavailableText(device: device, reason: reason)
            case .noTarget:
                Text("newconv.noAvailableTarget", tableName: table, bundle: .module)
            }
        }
    }
}

/// 分组标题：小号等宽字。作为列表里的一行而不是 Section 头：无障碍树把 Section 头排在各行之后，
/// 读屏时就分不清哪几行属于哪一组。
private struct SectionTitle: View {
    let title: Text

    var body: some View {
        title
            .font(.agentre(FontRole(size: 11, relativeTo: .caption), mono: true))
            .tracking(1.3)
            .foregroundStyle(.token(.ink3))
            .padding(EdgeInsets(top: 16, leading: 2, bottom: 8, trailing: 2))
            .accessibilityAddTraits(.isHeader)
    }
}

private extension View {
    func newConversationRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
    }

    func newConversationList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .background(.token(.bg))
    }
}

// MARK: 05 选 Agent

/// 新建对话入口：搜索、从项目里挑（写项目个数）、最近用过、全部 Agent。选的是 Agent，不是机器。
public struct NewConversationView: View {
    @Bindable private var model: NewConversationModel
    private let onPick: (WorkspaceAgent) -> Void
    private let onBrowseProjects: () -> Void

    /// - Parameters:
    ///   - onPick: 选中一个 Agent，进入它的草稿对话。导航归宿主。
    ///   - onBrowseProjects: 进「从项目里挑」。
    public init(model: NewConversationModel, onPick: @escaping (WorkspaceAgent) -> Void, onBrowseProjects: @escaping () -> Void) {
        self.model = model
        self.onPick = onPick
        self.onBrowseProjects = onBrowseProjects
    }

    public var body: some View {
        List {
            SearchField(text: $model.query, placeholder: "newconv.search", table: table)
                .padding(EdgeInsets(top: 12, leading: 0, bottom: 14, trailing: 0))
                .newConversationRow()

            if model.loadFailed {
                HStack {
                    Text("newconv.loadFailed", tableName: table, bundle: .module)
                        .font(.agentre(.subheadline))
                        .foregroundStyle(.token(.coral))
                    Spacer()
                    Button {
                        Task { await model.load() }
                    } label: {
                        Text("newconv.retry", tableName: table, bundle: .module)
                            .font(.agentre(.subheadline, weight: .semibold))
                            .foregroundStyle(.token(.primary))
                    }
                    .hitTarget()
                }
                .newConversationRow()
            }

            if model.isSearching {
                ForEach(model.visibleAgents) { SummaryAgentRow(agent: $0, onPick: onPick).newConversationRow() }
            } else {
                fromProjectCard.newConversationRow()
                if !model.recent.isEmpty {
                    SectionTitle(title: Text("newconv.recent", tableName: table, bundle: .module)).newConversationRow()
                    ForEach(model.recent) { SummaryAgentRow(agent: $0, onPick: onPick).newConversationRow() }
                }
                SectionTitle(title: Text("newconv.allAgents", tableName: table, bundle: .module)).newConversationRow()
                ForEach(model.agents) { SummaryAgentRow(agent: $0, onPick: onPick).newConversationRow() }
            }
        }
        .newConversationList()
    }

    /// 「从项目里挑」卡片：`surface` 圆角描边，副行写项目个数。
    private var fromProjectCard: some View {
        Button(action: onBrowseProjects) {
            HStack(spacing: 11) {
                Image(.folderTree)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.token(.primary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("newconv.fromProject", tableName: table, bundle: .module)
                        .font(.agentre(FontRole(size: 14.5, weight: .medium, relativeTo: .body)))
                        .foregroundStyle(.token(.ink))
                    Text("newconv.projectCount \(model.projectCount)", tableName: table, bundle: .module)
                        .font(.agentre(.caption))
                        .foregroundStyle(.token(.ink3))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(.chevronRight)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.token(.ink3))
                    .accessibilityHidden(true)
            }
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
            .background(.token(.surface), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.token(.line)))
        }
        .hitTarget()
    }
}

// MARK: 05B 从项目里挑

/// 「从项目里挑」：顶上横向滚动的项目胶囊（子项目写「父 › 子」），下面是选中项目的直接成员，
/// 再按祖先由近到远各一组「继承自 <祖先>」。每行写这个项目下的派发结果。
public struct NewConversationProjectPicker: View {
    private let model: NewConversationModel
    private let onPick: (WorkspaceAgent, WorkspaceProject) -> Void

    /// - Parameter onPick: 在选中的项目下选了一个 Agent，进入它的草稿对话（项目随之带上）。导航归宿主。
    public init(model: NewConversationModel, onPick: @escaping (WorkspaceAgent, WorkspaceProject) -> Void) {
        self.model = model
        self.onPick = onPick
    }

    private var selected: WorkspaceProject? {
        model.selectedProjectID.flatMap { id in model.projects.first { $0.syncID == id } }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !model.projectRows.isEmpty { pills }
            List {
                if model.projectRows.isEmpty {
                    Text("newconv.noProjects", tableName: table, bundle: .module)
                        .font(.agentre(.subheadline))
                        .foregroundStyle(.token(.ink2))
                        .padding(.top, 16)
                        .newConversationRow()
                } else if let selected {
                    members(of: selected)
                }
            }
            .newConversationList()
        }
        .background(.token(.bg))
        .task {
            guard model.selectedProjectID == nil, let first = model.projectRows.first else { return }
            await model.selectProject(first.id)
        }
    }

    private var pills: some View {
        HorizontalScroller {
            HStack(spacing: 8) {
                ForEach(model.projectRows) { row in
                    ProjectPill(row: row, selected: row.id == model.selectedProjectID) {
                        Task { await model.selectProject(row.id) }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(.token(.line)).frame(height: 1) }
    }

    @ViewBuilder private func members(of project: WorkspaceProject) -> some View {
        let membership = model.membership(of: project.syncID)
        if membership.direct.isEmpty && membership.inherited.isEmpty {
            Text("newconv.noAgentsInProject", tableName: table, bundle: .module)
                .font(.agentre(.subheadline))
                .foregroundStyle(.token(.ink2))
                .padding(.top, 16)
                .newConversationRow()
        }
        if !membership.direct.isEmpty {
            SectionTitle(title: Text("newconv.directMembers", tableName: table, bundle: .module)).newConversationRow()
            ForEach(membership.direct) { row($0, in: project) }
        }
        ForEach(membership.inherited, id: \.ancestor.syncID) { group in
            SectionTitle(title: Text("newconv.inheritedFrom \(Text(verbatim: group.ancestor.name))", tableName: table, bundle: .module))
                .newConversationRow()
            ForEach(group.agents) { row($0, in: project) }
        }
    }

    private func row(_ agent: WorkspaceAgent, in project: WorkspaceProject) -> some View {
        let landing = model.landing(of: agent.syncID, in: project.syncID)
        return AgentRow(agent: agent, available: Self.isAvailable(landing, agent: agent), onPick: { onPick(agent, project) }) {
            switch landing {
            case nil:
                ProgressView().controlSize(.mini)
            case .resolved(.landsOn(let device, let cwd)) where cwd.isEmpty:
                Text("newconv.currentTarget \(machineText(device))", tableName: table, bundle: .module)
            case .resolved(.landsOn(let device, let cwd)):
                Text("newconv.landsOnPath \(machineText(device)) \(machineText(cwd))", tableName: table, bundle: .module)
            case .resolved(.unavailable(let device, let reason)):
                unavailableText(device: device, reason: reason)
            case .resolved(.noTarget):
                Text("newconv.noAvailableTarget", tableName: table, bundle: .module)
            case .failed:
                Text("newconv.planFailed", tableName: table, bundle: .module)
            }
        }
        .newConversationRow()
    }

    /// 问到了就按这个项目下的结果（项目在机器上没配路径即不可用）；还在问或没问到时按清单，草稿里会再解析一次。
    private static func isAvailable(_ landing: ProjectLandingState?, agent: WorkspaceAgent) -> Bool {
        switch landing {
        case .resolved(.landsOn): true
        case .resolved: false
        case nil, .failed: agent.hasAvailableTarget
        }
    }
}

/// 一枚项目胶囊：绘制 32pt 高，命中区由 `hitTarget()` 补满 44；选中项为 `primary` 实心。
private struct ProjectPill: View {
    let row: WorkspaceProjectRow
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: row.trail.joined(separator: " › "))
                .font(.agentre(.subheadline, weight: selected ? .semibold : .regular))
                .foregroundStyle(.token(selected ? .primaryInk : .ink2))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minWidth: minimumHitTargetSide, minHeight: 32)
                .background(.token(selected ? .primary : .surface), in: Capsule())
                .overlay {
                    if !selected { Capsule().strokeBorder(.token(.line)) }
                }
        }
        .hitTarget()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
