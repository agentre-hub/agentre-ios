import AgentreDesign
import AgentreDomain
import SwiftUI

/// 「我」：账号、服务器地址、已授权设备与撤销、语言、外观、退出登录。
/// 状态只由内容与可供性表达，不加说明文案。
public struct MeView: View {
    private let model: MeModel
    @State private var isEditingServer = false
    @State private var draftAddress = ""
    @State private var draftIsInvalid = false
    @State private var pendingServer: ServerAddress?
    @State private var pendingRevoke: AuthorizedDevice?

    public init(model: MeModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if let failure = model.failure {
                Section {
                    FailureNotice(fact: failure) { Task { await model.load() } }
                        .listRowBackground(Color.token(.surface))
                }
            }
            if let profile = model.profile {
                Section { account(profile) } header: { header("me.account") }
            }
            Section { server } header: { header("me.server") }
            if !model.devices.isEmpty {
                Section {
                    ForEach(model.devices) { device in
                        DeviceRow(device: device) { pendingRevoke = device }
                            .listRowBackground(Color.token(.surface))
                    }
                } header: { header("me.devices") }
            }
            Section {
                ForEach(DisplayLanguage.allCases, id: \.self) { language in
                    option(language.labelKey, selected: model.preferences.language == language) { model.setLanguage(language) }
                }
            } header: { header("me.language") }
            Section {
                ForEach(DisplayAppearance.allCases, id: \.self) { appearance in
                    option(appearance.labelKey, selected: model.preferences.appearance == appearance) { model.setAppearance(appearance) }
                }
            } header: { header("me.appearance") }
            Section {
                Button {
                    Task { await model.signOut() }
                } label: {
                    Text("me.signOut", tableName: "Me", bundle: .module)
                        .foregroundStyle(.token(.failure))
                        .frame(maxWidth: .infinity)
                }
                .hitTarget()
                .listRowBackground(Color.token(.surface))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.token(.bg))
        .localizedNavigationTitle("me.title", table: "Me")
        .confirmationDialog(Text("me.devices.revoke", tableName: "Me", bundle: .module), isPresented: isPresented($pendingRevoke), titleVisibility: .hidden, presenting: pendingRevoke) { device in
            Button(role: .destructive) {
                Task { await model.revoke(device) }
            } label: {
                Text("me.devices.revoke", tableName: "Me", bundle: .module)
            }
        }
        .confirmationDialog(Text("me.server.switch", tableName: "Me", bundle: .module), isPresented: isPresented($pendingServer), titleVisibility: .hidden, presenting: pendingServer) { address in
            Button(role: .destructive) {
                isEditingServer = false
                Task { _ = await model.setServerAddress(address.url.absoluteString) }
            } label: {
                Text("me.server.switch", tableName: "Me", bundle: .module)
            }
        }
        .task { await model.load() }
    }

    private func header(_ key: LocalizedStringKey) -> some View {
        Text(key, tableName: "Me", bundle: .module)
            .foregroundStyle(.token(.textSecondary))
    }

    @ViewBuilder private func account(_ profile: AccountProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: profile.shownName)
                .font(.headline)
                .foregroundStyle(.token(.textPrimary))
            if !profile.email.isEmpty, profile.email != profile.shownName {
                Text(verbatim: profile.email)
                    .font(.subheadline)
                    .foregroundStyle(.token(.textSecondary))
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.token(.surface))
    }

    @ViewBuilder private var server: some View {
        if isEditingServer {
            VStack(alignment: .leading, spacing: 8) {
                AddressField(text: $draftAddress, onSubmit: saveServer)
                if draftIsInvalid {
                    Label {
                        Text("me.server.invalid", tableName: "Me", bundle: .module)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.token(.failure))
                    }
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        isEditingServer = false
                    } label: {
                        Text("me.server.cancel", tableName: "Me", bundle: .module)
                            .foregroundStyle(.token(.textSecondary))
                            .padding(.horizontal, 8)
                    }
                    .hitTarget()
                    Button(action: saveServer) {
                        Text("me.server.save", tableName: "Me", bundle: .module)
                            .fontWeight(.semibold)
                            .foregroundStyle(.token(.accent))
                            .padding(.horizontal, 8)
                    }
                    .hitTarget()
                }
            }
            .listRowBackground(Color.token(.surface))
        } else {
            HStack(spacing: 8) {
                // 机器产出的内容用等宽字体。
                Text(verbatim: model.serverAddress.url.absoluteString)
                    .font(.body.monospaced())
                    .foregroundStyle(.token(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    draftAddress = model.serverAddress.url.absoluteString
                    draftIsInvalid = false
                    isEditingServer = true
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.token(.accent))
                }
                .hitTarget()
                .accessibilityLabel(Text("me.server.edit", tableName: "Me", bundle: .module))
            }
            .listRowBackground(Color.token(.surface))
        }
    }

    private func saveServer() {
        guard let address = ServerAddress(string: draftAddress) else {
            draftIsInvalid = true
            return
        }
        draftIsInvalid = false
        if address == model.serverAddress {
            isEditingServer = false
        } else {
            pendingServer = address
        }
    }

    private func option(_ key: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(key, tableName: "Me", bundle: .module)
                    .foregroundStyle(.token(.textPrimary))
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(.token(.accent))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .hitTarget()
        .accessibilityAddTraits(selected ? .isSelected : [])
        .listRowBackground(Color.token(.surface))
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
                    .fill(.token(device.online ? .running : .textSecondary))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: device.shownName)
                        .font(.body.monospaced())
                        .foregroundStyle(.token(.textPrimary))
                        .lineLimit(stacked ? nil : 1)
                        .truncationMode(.middle)
                    facts {
                        // 在线与否写出来：状态不只靠那枚点的颜色。
                        Text(device.online ? "me.devices.online" : "me.devices.offline", tableName: "Me", bundle: .module)
                            .font(.caption)
                            .foregroundStyle(.token(device.online ? .running : .textSecondary))
                        if !device.platform.isEmpty {
                            Text(verbatim: device.platform)
                                .font(.caption.monospaced())
                                .foregroundStyle(.token(.textSecondary))
                        }
                        if device.isThisDevice {
                            Text("me.devices.thisDevice", tableName: "Me", bundle: .module)
                                .font(.caption)
                                .foregroundStyle(.token(.accent))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 服务端只允许设备令牌撤销它自己：其它设备在这里撤不动，那一行如实写明去哪儿撤。
            if device.isThisDevice {
                Button(action: onRevoke) {
                    Text("me.devices.revoke", tableName: "Me", bundle: .module)
                        .foregroundStyle(.token(.failure))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
            } else {
                Text("me.devices.revokeInConsole", tableName: "Me", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.token(.textSecondary))
                    .multilineTextAlignment(stacked ? .leading : .trailing)
            }
        }
    }
}

private extension DisplayLanguage {
    var labelKey: LocalizedStringKey {
        switch self {
        case .system: "me.language.system"
        case .simplifiedChinese: "me.language.zhHans"
        case .english: "me.language.en"
        }
    }
}

private extension DisplayAppearance {
    var labelKey: LocalizedStringKey {
        switch self {
        case .system: "me.appearance.system"
        case .light: "me.appearance.light"
        case .dark: "me.appearance.dark"
        }
    }
}
