import AgentreDesign
import AgentreDomain
import SwiftUI

/// 机器标签：账号名下的机器与各自的在线态。每台机器一行，点进去是它的详情。
public struct MachinesView: View {
    private let model: MachinesModel
    private let onOpen: (Machine) -> Void

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
            } else if let reason = model.unavailable {
                FailureNotice(fact: .noMachineAvailable(reason)) {}
                    .machinesRow()
            }
            ForEach(model.machines) { machine in
                Button {
                    onOpen(machine)
                } label: {
                    MachineRosterRow(machine: machine)
                }
                .hitTarget()
                .machinesRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.token(.bg))
        .localizedNavigationTitle("machines.title", table: "Machines")
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}

private extension View {
    func machinesRow() -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// 一行：在线点、机器名（等宽：机器产出的内容），在线态与最后在线时刻。
private struct MachineRosterRow: View {
    let machine: Machine

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.token(machine.online ? .running : .textSecondary))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: machine.name)
                    .font(.body.monospaced())
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                MachinePresenceLine(machine: machine)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// 在线，或「不在线」加最后在线的时刻。
struct MachinePresenceLine: View {
    let machine: Machine

    var body: some View {
        if machine.online {
            Text("machines.online", tableName: "Machines", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.token(.running))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("machines.offline", tableName: "Machines", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.token(.textSecondary))
                if machine.lastSeenAt > 0 {
                    Text("machines.lastSeen \(Text(Date(timeIntervalSince1970: TimeInterval(machine.lastSeenAt) / 1000), format: .relative(presentation: .named)))", tableName: "Machines", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.token(.textSecondary))
                }
            }
        }
    }
}
