import AgentreDesign
import AgentreDomain
import SwiftUI

/// 登录屏：当前服务器地址与一个主操作。主操作发起设备流并直接打开带确认码的验证地址，
/// 用户不必手输确认码；等待、过期、被拒、失败都由按钮与一行状态表达，不加说明文案。
public struct LoginView: View {
    @Bindable private var flow: LoginFlow
    @State private var isEditingServer: Bool
    @State private var draftAddress = ""
    @State private var draftIsInvalid = false

    public init(flow: LoginFlow) {
        self.init(flow: flow, isEditingServer: false)
    }

    init(flow: LoginFlow, isEditingServer: Bool) {
        self.flow = flow
        _isEditingServer = State(initialValue: isEditingServer)
        _draftAddress = State(initialValue: flow.serverAddress.url.absoluteString)
    }

    private var isAwaiting: Bool { flow.state == .awaitingApproval }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(verbatim: "Agentre")
                .font(.largeTitle.bold())
                .foregroundStyle(.token(.textPrimary))
            server
            Spacer()
            outcome
            signInButton
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.token(.bg))
    }

    @ViewBuilder private var server: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 改地址的按钮与标题同一行，地址独占整行宽：默认地址在默认字号下一行排下，
            // 更长的地址或更大的字号换行而不截断——地址是要被核对的，不能只露两头。
            HStack(spacing: 8) {
                Text("login.server", tableName: "Login", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !isEditingServer {
                    Button {
                        draftAddress = flow.serverAddress.url.absoluteString
                        draftIsInvalid = false
                        isEditingServer = true
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(.token(.accent))
                    }
                    .hitTarget()
                    .disabled(isAwaiting)
                    .accessibilityLabel(Text("login.server.edit", tableName: "Login", bundle: .module))
                }
            }
            if isEditingServer {
                serverEditor
            } else {
                Text(verbatim: flow.serverAddress.url.absoluteString)
                    .font(.body.monospaced())
                    .foregroundStyle(.token(.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var serverEditor: some View {
        AddressField(text: $draftAddress, onSubmit: save)
        if draftIsInvalid {
            Label {
                Text("login.server.invalid", tableName: "Login", bundle: .module)
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
                Text("login.server.cancel", tableName: "Login", bundle: .module)
                    .foregroundStyle(.token(.textSecondary))
                    .padding(.horizontal, 8)
            }
            .hitTarget()
            Button(action: save) {
                Text("login.server.save", tableName: "Login", bundle: .module)
                    .fontWeight(.semibold)
                    .foregroundStyle(.token(.accent))
                    .padding(.horizontal, 8)
            }
            .hitTarget()
            // 等待授权期间地址不可改（设备流在发起时的服务器上换令牌）。
            .disabled(isAwaiting)
        }
    }

    @ViewBuilder private var outcome: some View {
        switch flow.state {
        case .expired:
            status("login.expired", systemImage: "clock.badge.exclamationmark")
        case .denied:
            status("login.denied", systemImage: "hand.raised")
        case .failed:
            status("login.failed", systemImage: "wifi.exclamationmark")
        case .idle, .awaitingApproval, .signedIn:
            EmptyView()
        }
    }

    /// 收场状态：图标 + 文字，不只靠颜色。
    private func status(_ key: LocalizedStringKey, systemImage: String) -> some View {
        Label {
            Text(key, tableName: "Login", bundle: .module)
                .foregroundStyle(.token(.textPrimary))
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.token(.failure))
        }
        .font(.callout)
    }

    private var signInButton: some View {
        Button {
            Task { await flow.signIn() }
        } label: {
            HStack(spacing: 8) {
                if isAwaiting {
                    ProgressView()
                        .tint(.token(.onAccent))
                    Text("login.awaiting", tableName: "Login", bundle: .module)
                } else if flow.state == .idle {
                    Text("login.signIn", tableName: "Login", bundle: .module)
                } else {
                    Text("login.signIn.again", tableName: "Login", bundle: .module)
                }
            }
            .font(.headline)
            .foregroundStyle(.token(.onAccent))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(.token(.accent), in: Capsule())
            .opacity(isAwaiting ? 0.7 : 1)
        }
        .hitTarget()
        .disabled(isAwaiting)
    }

    private func save() {
        guard !isAwaiting else { return }
        guard flow.setServerAddress(draftAddress) else {
            draftIsInvalid = true
            return
        }
        isEditingServer = false
    }
}
