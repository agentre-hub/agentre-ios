import AgentreDesign
import AgentreDomain
import SwiftUI

/// 「服务器」二级页：地址编辑，改到另一台不同的服务器即确认后退出登录——手里的令牌与本地会话
/// 属于原来那台服务器上的账号，不能带过去（`MeModel.setServerAddress`）。
public struct ServerAddressScreen: View {
    private let model: MeModel
    @State private var draftAddress: String
    @State private var draftIsInvalid = false
    @State private var pendingServer: ServerAddress?
    @Environment(\.dismiss) private var dismiss

    public init(model: MeModel) {
        self.model = model
        _draftAddress = State(initialValue: model.serverAddress.url.absoluteString)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupedSection {
                VStack(alignment: .leading, spacing: 8) {
                    AddressField(text: $draftAddress, onSubmit: save)
                    if draftIsInvalid {
                        Label {
                            Text("me.server.invalid", tableName: "Me", bundle: .module)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.token(.coral))
                        }
                        .font(.agentre(.footnote))
                        .foregroundStyle(.token(.ink2))
                    }
                }
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
            }
            HStack(spacing: 8) {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("me.server.cancel", tableName: "Me", bundle: .module)
                        .font(.agentre(.body))
                        .foregroundStyle(.token(.ink2))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
                Button(action: save) {
                    Text("me.server.save", tableName: "Me", bundle: .module)
                        .font(.agentre(.body, weight: .semibold))
                        .foregroundStyle(.token(.primary))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.token(.bg))
        .confirmationDialog(
            Text("me.server.switch", tableName: "Me", bundle: .module), isPresented: isPresented($pendingServer), titleVisibility: .hidden,
            presenting: pendingServer
        ) { address in
            Button(role: .destructive) {
                Task { _ = await model.setServerAddress(address.url.absoluteString) }
            } label: {
                Text("me.server.switch", tableName: "Me", bundle: .module)
            }
        }
    }

    private func save() {
        guard let address = ServerAddress(string: draftAddress) else {
            draftIsInvalid = true
            return
        }
        draftIsInvalid = false
        if address == model.serverAddress {
            dismiss()
        } else {
            pendingServer = address
        }
    }

    private func isPresented<T>(_ binding: Binding<T?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
    }
}
