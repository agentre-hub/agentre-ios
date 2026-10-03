import AgentreDesign
import AgentreDomain
import SwiftUI

/// 机器详情：顶上是机器现算的三个计数，下面是它的会话（现问它要，按游标翻页、按标题搜索）。
/// 已保存的行点进对话；未保存的行给出「保存到手机」。机器离线时只呈现它不在线。
public struct MachineDetailView: View {
    private let model: MachineDetailModel
    private let onOpen: (ConversationKey) -> Void
    @State private var query = ""
    @Environment(\.isOffline) private var isOffline

    /// - Parameter onOpen: 进入一条已保存的对话。导航归宿主。
    public init(model: MachineDetailModel, onOpen: @escaping (ConversationKey) -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    public var body: some View {
        content
            .background(.token(.bg))
            .task {
                await model.load()
                await model.follow()
            }
    }

    @ViewBuilder private var content: some View {
        if model.machine.online {
            List {
                if let counts = model.counts {
                    MachineCountsHeader(counts: counts)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                SearchField(text: $query, placeholder: "machines.detail.search", table: "Machines") { Task { await model.search(query) } }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                if isOffline {
                    // 本机没网：如实说是离线，而不是说没连上那台机器。
                    Label {
                        Text("machines.detail.deviceOffline", tableName: "Machines", bundle: .module)
                    } icon: {
                        Image(systemName: "wifi.slash")
                    }
                    .font(.agentre(.subheadline))
                    .foregroundStyle(.token(.ink2))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if model.updateRequired {
                    Text(LocalizedStringKey(failureKey(.updateRequired)), tableName: "Me", bundle: .module)
                        .font(.agentre(.subheadline))
                        .foregroundStyle(.token(.ink2))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if model.unreachable {
                    Text("machines.detail.unreachable", tableName: "Machines", bundle: .module)
                        .font(.agentre(.subheadline))
                        .foregroundStyle(.token(.ink2))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                let rows = model.rows
                ForEach(rows) { row in
                    MachineSessionRowView(row: row, isLast: row.id == rows.last?.id, onOpen: onOpen) {
                        Task { await model.save(row.id) }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                if let reloadCount = model.reloadCount {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        Text("machines.detail.reloadMore \(reloadCount)", tableName: "Machines", bundle: .module)
                            .font(.agentre(.subheadline, weight: .medium))
                            .foregroundStyle(.token(.primary))
                            .frame(maxWidth: .infinity)
                    }
                    .hitTarget()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty, !model.keyword.isEmpty { Task { await model.search("") } }
            }
            .refreshable { await model.load() }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.agentre(.display))
                    .foregroundStyle(.token(.ink2))
                    .accessibilityHidden(true)
                Text("machines.detail.offline", tableName: "Machines", bundle: .module)
                    .font(.agentre(.subheadline))
                    .foregroundStyle(.token(.ink2))
                if model.machine.lastSeenAt > 0 {
                    Text(
                        "machines.lastSeen \(Text(Date(timeIntervalSince1970: TimeInterval(model.machine.lastSeenAt) / 1000), format: .relative(presentation: .named)))",
                        tableName: "Machines", bundle: .module
                    )
                    .font(.agentre(.caption))
                    .foregroundStyle(.token(.ink2))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 顶上的三个计数：总数、运行中、等你处理。
private struct MachineCountsHeader: View {
    let counts: MachineSessionCounts

    var body: some View {
        HStack(spacing: 12) {
            cell(counts.total, "machines.detail.count.total", .ink)
            cell(counts.running, "machines.detail.count.running", .run)
            cell(counts.waiting, "machines.detail.count.waiting", .amber)
        }
    }

    private func cell(_ value: Int64, _ label: LocalizedStringKey, _ token: ColorToken) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(.agentre(.title))
                .monospacedDigit()
                .foregroundStyle(.token(token))
            Text(label, tableName: "Machines", bundle: .module)
                .font(.agentre(.caption))
                .foregroundStyle(.token(.ink2))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 一条会话，平铺行加分隔线（不做卡片，与稿子同）。已保存：整行是进入对话的按钮，带「在手机上」的标记；
/// 未保存：行本身不可点，尾部是「保存到手机」。
private struct MachineSessionRowView: View {
    let row: MachineSessionRow
    /// 最后一行底下不画分隔线。
    let isLast: Bool
    let onOpen: (ConversationKey) -> Void
    let onSave: () -> Void
    /// 保存要机器来答：离线时点不动。
    @Environment(\.isOffline) private var isOffline

    var body: some View {
        if row.isSaved {
            // 已保存：整行是进入对话的按钮，行尾是进入的展开指示（规格「06」：「已保存的是进入对话的展开指示」）。
            Button {
                onOpen(row.key)
            } label: {
                card {
                    Image(.chevronRight)
                        .foregroundStyle(.token(.ink2))
                        .accessibilityLabel(Text("machines.detail.saved", tableName: "Machines", bundle: .module))
                }
            }
            .hitTarget()
        } else {
            card {
                if row.isSaving {
                    ProgressView()
                        .frame(width: minimumHitTargetSide, height: minimumHitTargetSide)
                } else {
                    Button(action: onSave) {
                        Image(systemName: row.saveFailed ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90" : "square.and.arrow.down")
                            .foregroundStyle(.token(row.saveFailed ? .coral : .primary))
                            .accessibilityLabel(Text("machines.detail.save", tableName: "Machines", bundle: .module))
                    }
                    .hitTarget()
                    .disabled(isOffline)
                }
            }
        }
    }

    /// 状态点、标题叠等宽工作目录、行尾相对时间，再是进入指示或保存入口；行下一条 `line` 分隔线，避开状态点。
    private func card(@ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            ConversationStatusGlyph(activity: row.session.activity)
            VStack(alignment: .leading, spacing: 3) {
                title
                if !row.session.cwd.isEmpty {
                    Text(verbatim: row.session.cwd)
                        .font(.agentre(.caption2, mono: true))
                        .foregroundStyle(.token(.ink3))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if row.session.lastMessageAt > 0 {
                Text(Date(timeIntervalSince1970: TimeInterval(row.session.lastMessageAt) / 1000), format: .relative(presentation: .named))
                    .font(.agentre(.caption))
                    .foregroundStyle(.token(.ink3))
                    .lineLimit(1)
            }
            trailing()
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(.token(.line)).frame(height: 1).padding(.leading, Self.dividerInset)
            }
        }
    }

    /// 状态图标列（14）加间距（12）：分隔线与标题对齐。
    private static let dividerInset: CGFloat = 14 + 12

    @ViewBuilder private var title: some View {
        if row.session.title.isEmpty {
            Text(verbatim: row.session.conversationID)
                .font(.agentre(.body, mono: true))
                .foregroundStyle(.token(.ink))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(verbatim: row.session.title)
                .font(.agentre(.body))
                .foregroundStyle(.token(.ink))
                .lineLimit(1)
        }
    }
}
