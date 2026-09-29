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

/// 机器产出的内容（机器名、后端种类）以等宽字体呈现。
private func machineText(_ value: String) -> Text {
    Text(verbatim: value).font(.subheadline.monospaced())
}

/// 选 Agent 的一行：名字，下面是解析结果——当前落到哪台机器，或跑不了的具体原因。跑不了的行压暗、不可点。
private struct AgentRow: View {
    let agent: WorkspaceAgent
    let onPick: (WorkspaceAgent) -> Void

    var body: some View {
        Button {
            onPick(agent)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: agent.name)
                    .font(.body)
                    .foregroundStyle(.token(.ink))
                summary
                    .font(.subheadline)
                    .foregroundStyle(.token(.ink2))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .hitTarget()
        .disabled(!agent.hasAvailableTarget)
        .opacity(agent.hasAvailableTarget ? 1 : 0.45)
    }

    @ViewBuilder private var summary: some View {
        switch agent.targetSummary {
        case .landsOn(let device):
            Text("newconv.currentTarget \(machineText(device))", tableName: table, bundle: .module)
        case .landsOnThisDevice:
            Text("newconv.currentTarget \(Text("newconv.thisDevice", tableName: table, bundle: .module))", tableName: table, bundle: .module)
        case .unavailable(let device, let reason) where !device.isEmpty:
            Text("newconv.unavailableOn \(machineText(device)) \(Text(reasonKey(reason), tableName: table, bundle: .module))", tableName: table, bundle: .module)
        case .unavailable(_, let reason):
            NewConversationReasonText(availability: reason)
        case .noTarget:
            Text("newconv.noAvailableTarget", tableName: table, bundle: .module)
        }
    }
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

/// 分组标题。作为列表里的一行而不是 Section 头：无障碍树把 Section 头排在各行之后，
/// 读屏时就分不清哪几行属于哪一组。
private struct SectionTitle: View {
    let key: LocalizedStringKey

    var body: some View {
        Text(key, tableName: table, bundle: .module)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.token(.ink2))
            .accessibilityAddTraits(.isHeader)
    }
}

private extension View {
    func newConversationRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
    }

    func newConversationList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.token(.bg))
    }
}

// MARK: 入口

/// 新建对话入口：搜索、从项目里挑、最近用过、全部 Agent。选的是 Agent，不是机器。
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
            NewConversationSearchField(text: $model.query, placeholder: LocalizedCopy("newconv.search", table: table))
                .newConversationRow()

            if model.loadFailed {
                HStack {
                    Text("newconv.loadFailed", tableName: table, bundle: .module)
                        .foregroundStyle(.token(.coral))
                    Spacer()
                    Button {
                        Task { await model.load() }
                    } label: {
                        Text("newconv.retry", tableName: table, bundle: .module)
                            .foregroundStyle(.token(.primary))
                    }
                    .hitTarget()
                }
                .newConversationRow()
            }

            if model.isSearching {
                ForEach(model.visibleAgents) { AgentRow(agent: $0, onPick: onPick).newConversationRow() }
            } else {
                Button(action: onBrowseProjects) {
                    Label {
                        Text("newconv.fromProject", tableName: table, bundle: .module)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .foregroundStyle(.token(.primary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .hitTarget()
                .newConversationRow()

                if !model.recent.isEmpty {
                    SectionTitle(key: "newconv.recent")
                        .padding(.top, 12)
                        .newConversationRow()
                    ForEach(model.recent) { AgentRow(agent: $0, onPick: onPick).newConversationRow() }
                }
                SectionTitle(key: "newconv.allAgents")
                    .padding(.top, 12)
                    .newConversationRow()
                ForEach(model.agents) { AgentRow(agent: $0, onPick: onPick).newConversationRow() }
            }
        }
        .newConversationList()
        .localizedNavigationTitle("newconv.title", table: table)
    }
}

// MARK: 从项目里挑

/// 「从项目里挑」第一步：选项目。项目是一棵树，子项目缩进在父项目下。
public struct NewConversationProjectList: View {
    private let model: NewConversationModel
    private let onPick: (WorkspaceProject) -> Void

    public init(model: NewConversationModel, onPick: @escaping (WorkspaceProject) -> Void) {
        self.model = model
        self.onPick = onPick
    }

    public var body: some View {
        List {
            if model.projectRows.isEmpty {
                Text("newconv.noProjects", tableName: table, bundle: .module)
                    .foregroundStyle(.token(.ink2))
                    .newConversationRow()
            }
            ForEach(model.projectRows) { row in
                Button {
                    onPick(row.project)
                } label: {
                    Label {
                        Text(verbatim: row.project.name).foregroundStyle(.token(.ink))
                    } icon: {
                        Image(systemName: "folder").foregroundStyle(.token(.ink2))
                    }
                    .padding(.leading, CGFloat(row.depth) * 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .hitTarget()
                .newConversationRow()
            }
        }
        .newConversationList()
        .localizedNavigationTitle("newconv.projects", table: table)
    }
}

/// 「从项目里挑」第二步：项目下的 Agent，直接加入的与继承自父项目的分两组标注。
public struct NewConversationProjectAgents: View {
    private let model: NewConversationModel
    private let project: WorkspaceProject
    private let onPick: (WorkspaceAgent) -> Void

    public init(model: NewConversationModel, project: WorkspaceProject, onPick: @escaping (WorkspaceAgent) -> Void) {
        self.model = model
        self.project = project
        self.onPick = onPick
    }

    public var body: some View {
        let membership = model.membership(of: project.syncID)
        List {
            if membership.direct.isEmpty && membership.inherited.isEmpty {
                Text("newconv.noAgentsInProject", tableName: table, bundle: .module)
                    .foregroundStyle(.token(.ink2))
                    .newConversationRow()
            }
            if !membership.direct.isEmpty {
                SectionTitle(key: "newconv.directMembers")
                    .padding(.top, 12)
                    .newConversationRow()
                ForEach(membership.direct) { AgentRow(agent: $0, onPick: onPick).newConversationRow() }
            }
            if !membership.inherited.isEmpty {
                SectionTitle(key: "newconv.inheritedMembers")
                    .padding(.top, 12)
                    .newConversationRow()
                ForEach(membership.inherited) { AgentRow(agent: $0, onPick: onPick).newConversationRow() }
            }
        }
        .newConversationList()
        .navigationTitle(Text(verbatim: project.name))
    }
}
