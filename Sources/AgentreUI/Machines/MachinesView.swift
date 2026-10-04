import AgentreDesign
import AgentreDomain
import SwiftUI

/// 机器标签：账号名下的机器与各自的在线态。每台机器一行，点进去是它的详情。
public struct MachinesView: View {
    private let model: MachinesModel
    private let onOpen: (Machine) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isSelectedShellPage) private var isSelectedPage

    /// - Parameter onOpen: 进入一台机器的详情。导航归宿主。
    public init(model: MachinesModel, onOpen: @escaping (Machine) -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    public var body: some View {
        List {
            // 名册没取到、或账号下没有一台在线：如实说出来，而不是一片空白或无限等待。
            if let failure = model.failure {
                FailureNotice(fact: failure) { Task { await model.load() } }
                    .machinesRow()
            } else {
                // 副标题照数名册：一台都不在线时也写「N 台已配对 · 0 台在线」，与下面的「没有可用的机器」并存。
                if !model.machines.isEmpty {
                    Text("machines.subtitle \(model.machines.count) \(model.machines.filter(\.online).count)", tableName: "Machines", bundle: .module)
                        .font(.agentre(.subheadline))
                        .foregroundStyle(.token(.ink2))
                        .machinesRow()
                }
                if let reason = model.unavailable {
                    FailureNotice(fact: .noMachineAvailable(reason)) {}
                        .machinesRow()
                }
            }
            ForEach(model.machines) { machine in
                Button {
                    onOpen(machine)
                } label: {
                    MachineRosterRow(machine: machine, counts: model.counts[machine.fingerprint])
                }
                .hitTarget()
                .machinesRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.token(.bg))
        .task { await model.load() }
        .refreshable { await model.load() }
        // 回到前台：退到后台期间机器可能上线或下线了，按服务端此刻的名册重排（report-17 08c）。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        // 回到机器 tab：页一直挂着，进屏载入只跑过第一次；重新选中时同样按服务端此刻的名册重排。
        .onChange(of: isSelectedPage) { _, selected in
            if selected { Task { await model.load() } }
        }
    }
}

private extension View {
    func machinesRow() -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// 一张卡：状态点、等宽机器名、展开指示；等宽的「平台 · 种类 版本」一行；分隔线下是在线时现算的会话计数，
/// 离线时只写最后在线时刻、整卡压暗（规格「08」：离线机器的会话数没有来源，见 Out of scope）。
private struct MachineRosterRow: View {
    let machine: Machine
    /// 那台机器现算的会话计数；只在线且已答过时才有（决策 19：机器离线时这三个数一个都没有）。
    let counts: MachineSessionCounts?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // 纯装饰：在线态由下面分隔线以下的文字块（会话计数 或 最后在线时刻）写出来，不只靠这枚点的颜色。
                Circle()
                    .fill(.token(machine.online ? .run : .idle))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: machine.name)
                        .font(.agentre(.body, mono: true, weight: .semibold))
                        .foregroundStyle(.token(.ink))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let summary = machine.reportedSummary {
                        Text(verbatim: summary)
                            .font(.agentre(.caption, mono: true))
                            .foregroundStyle(.token(.ink3))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(.chevronRight)
                    .foregroundStyle(.token(.ink2))
                    .accessibilityHidden(true)
            }
            if machine.online {
                if let counts, counts.total > 0 {
                    Divider().overlay(.token(.line))
                    MachineActivitySummary(counts: counts)
                }
            } else if machine.lastSeenAt > 0 {
                Divider().overlay(.token(.line))
                Text("machines.lastSeen \(Text(Date(timeIntervalSince1970: TimeInterval(machine.lastSeenAt) / 1000), format: .relative(presentation: .named)))", tableName: "Machines", bundle: .module)
                    .font(.agentre(.caption))
                    .foregroundStyle(.token(.ink2))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .opacity(machine.online ? 1 : 0.45)
    }
}

/// 一行「N 个会话 · N 运行中 · N 等你处理」：各项各自成句、以「·」相隔，为零的项不写（决策 19）。
private struct MachineActivitySummary: View {
    let counts: MachineSessionCounts

    var body: some View {
        HStack(spacing: 4) {
            Text("machines.count.sessions \(counts.total)", tableName: "Machines", bundle: .module)
                .font(.agentre(.caption, weight: .medium))
                .foregroundStyle(.token(.run))
            if counts.running > 0 {
                separator
                Text("machines.count.running \(counts.running)", tableName: "Machines", bundle: .module)
            }
            if counts.waiting > 0 {
                separator
                Text("machines.count.waiting \(counts.waiting)", tableName: "Machines", bundle: .module)
            }
        }
        .font(.agentre(.caption))
        .foregroundStyle(.token(.ink2))
        .lineLimit(1)
    }

    private var separator: some View {
        Text(verbatim: "·").accessibilityHidden(true)
    }
}
