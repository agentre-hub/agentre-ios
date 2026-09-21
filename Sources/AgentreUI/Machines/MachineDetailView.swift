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
            .navigationTitle(Text(verbatim: model.machine.name))
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
                MachineSearchField(text: $query) { Task { await model.search(query) } }
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
                    .font(.subheadline)
                    .foregroundStyle(.token(.textSecondary))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if model.unreachable {
                    Text("machines.detail.unreachable", tableName: "Machines", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.token(.textSecondary))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(model.rows) { row in
                    MachineSessionRowView(row: row, onOpen: onOpen) {
                        Task { await model.save(row.id) }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        if row.id == model.rows.last?.id { Task { await model.loadMore() } }
                    }
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
                    .font(.largeTitle)
                    .foregroundStyle(.token(.textSecondary))
                    .accessibilityHidden(true)
                MachinePresenceLine(machine: model.machine)
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
            cell(counts.total, "machines.detail.count.total", .textPrimary)
            cell(counts.running, "machines.detail.count.running", .running)
            cell(counts.waiting, "machines.detail.count.waiting", .waiting)
        }
    }

    private func cell(_ value: Int64, _ label: LocalizedStringKey, _ token: ColorToken) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.token(token))
            Text(label, tableName: "Machines", bundle: .module)
                .font(.caption)
                .foregroundStyle(.token(.textSecondary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 一条会话。已保存：整行是进入对话的按钮，带「在手机上」的标记；
/// 未保存：行本身不可点，尾部是「保存到手机」。
private struct MachineSessionRowView: View {
    let row: MachineSessionRow
    let onOpen: (ConversationKey) -> Void
    let onSave: () -> Void
    /// 保存要机器来答：离线时点不动。
    @Environment(\.isOffline) private var isOffline

    var body: some View {
        if row.isSaved {
            Button {
                onOpen(row.key)
            } label: {
                card {
                    Image(systemName: "iphone")
                        .foregroundStyle(.token(.accent))
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
                            .foregroundStyle(.token(row.saveFailed ? .failure : .accent))
                            .accessibilityLabel(Text("machines.detail.save", tableName: "Machines", bundle: .module))
                    }
                    .hitTarget()
                    .disabled(isOffline)
                }
            }
        }
    }

    private func card(@ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.token(statusToken))
                .frame(width: 10, height: 10)
                .opacity(row.session.activity == .idle ? 0 : 1)
            VStack(alignment: .leading, spacing: 4) {
                title
                if row.session.lastMessageAt > 0 {
                    Text(Date(timeIntervalSince1970: TimeInterval(row.session.lastMessageAt) / 1000), format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.token(.textSecondary))
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var title: some View {
        if row.session.title.isEmpty {
            Text(verbatim: row.session.conversationID)
                .font(.body.monospaced())
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(verbatim: row.session.title)
                .font(.body)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
        }
    }

    private var statusToken: ColorToken {
        switch row.session.activity {
        case .waiting: .waiting
        case .typing: .running
        case .failed: .failure
        case .idle: .textSecondary
        }
    }
}
