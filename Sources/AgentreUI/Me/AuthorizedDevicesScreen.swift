import AgentreDesign
import AgentreDomain
import SwiftUI

/// 「已授权设备」二级页：撤销只对本机生效（服务端只允许设备令牌撤销它自己）。本机那一行的「撤销」
/// 与「退出登录」是同一个动作；其它设备那一行写明到网页控制台撤销，不给撤不动的按钮。
public struct AuthorizedDevicesScreen: View {
    private let model: MeModel
    @State private var pendingRevoke: AuthorizedDevice?

    public init(model: MeModel) {
        self.model = model
    }

    public var body: some View {
        List {
            // 列表一次都没取到：如实说没取到并给重试（失败事实在「我」页同一份），不是一张空列表。
            if model.devices == nil, let failure = model.failure {
                Section {
                    FailureNotice(fact: failure) { Task { await model.load() } }
                        .listRowBackground(Color.token(.surface))
                }
            }
            Section {
                ForEach(model.devices ?? []) { device in
                    DeviceRow(device: device) { pendingRevoke = device }
                        .listRowBackground(Color.token(.surface))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.token(.bg))
        .confirmationDialog(
            Text("me.devices.revoke", tableName: "Me", bundle: .module), isPresented: isPresented($pendingRevoke), titleVisibility: .hidden,
            presenting: pendingRevoke
        ) { _ in
            // 撤销本机就是退出登录（决策 22）：其它设备那一行不给撤销按钮，到网页控制台撤。
            Button(role: .destructive) {
                Task { await model.signOut() }
            } label: {
                Text("me.devices.revoke", tableName: "Me", bundle: .module)
            }
        }
    }

    private func isPresented<T>(_ binding: Binding<T?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
    }
}

/// 一台已授权设备：在线点、名字（备注名优先，等宽）、在线态、平台与本机标注；本机给撤销，其它设备写明到网页控制台撤销。
/// 无障碍字号下横排放不下：名字、状态与撤销出口改为自上而下，名字可折行而不截断，状态各占一行。
struct DeviceRow: View {
    let device: AuthorizedDevice
    let onRevoke: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let row = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        let facts = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
        row {
            HStack(spacing: 12) {
                Circle()
                    .fill(.token(device.online ? .run : .idle))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: device.shownName)
                        .font(.agentre(.body, mono: true))
                        .foregroundStyle(.token(.ink))
                        .lineLimit(stacked ? nil : 1)
                        .truncationMode(.middle)
                    facts {
                        // 在线与否写出来：状态不只靠那枚点的颜色。
                        Text(device.online ? "me.devices.online" : "me.devices.offline", tableName: "Me", bundle: .module)
                            .font(.agentre(.caption))
                            .foregroundStyle(.token(device.online ? .run : .ink2))
                        if !device.platform.isEmpty {
                            Text(verbatim: device.platform)
                                .font(.agentre(.caption, mono: true))
                                .foregroundStyle(.token(.ink2))
                        }
                        if device.isThisDevice {
                            Text("me.devices.thisDevice", tableName: "Me", bundle: .module)
                                .font(.agentre(.caption))
                                .foregroundStyle(.token(.primary))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 服务端只允许设备令牌撤销它自己：其它设备在这里撤不动，那一行如实写明去哪儿撤。
            if device.isThisDevice {
                Button(action: onRevoke) {
                    Text("me.devices.revoke", tableName: "Me", bundle: .module)
                        .font(.agentre(.subheadline, weight: .semibold))
                        .foregroundStyle(.token(.coral))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
            } else {
                Text("me.devices.revokeInConsole", tableName: "Me", bundle: .module)
                    .font(.agentre(.caption))
                    .foregroundStyle(.token(.ink2))
                    .multilineTextAlignment(stacked ? .leading : .trailing)
            }
        }
    }
}
