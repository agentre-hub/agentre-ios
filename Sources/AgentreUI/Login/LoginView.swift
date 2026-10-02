import AgentreDesign
import AgentreDomain
import SwiftUI

/// 登录屏：字标、标语、服务器行（主机名，点开可改）与主操作（规格「逐屏视觉契约·07 登录」）。
/// 主操作发起设备流并直接打开带确认码的验证地址，用户不必手输确认码；等待、过期、被拒、失败
/// 都由按钮与一行状态表达，不加说明文案。
public struct LoginView: View {
    @Bindable private var flow: LoginFlow
    @State private var isEditingServer: Bool
    @State private var draftAddress = ""
    @State private var draftIsInvalid = false
    @Environment(\.isOffline) private var isOffline

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
        VStack(alignment: .leading, spacing: 0) {
            top.padding(.top, 70)
            Spacer(minLength: 24)
            outcome
            bottom.padding(.bottom, 26)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.token(.bg))
    }

    @ViewBuilder private var top: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(verbatim: "AGENTRE")
                .font(.agentre(FontRole(size: 13, weight: .semibold, relativeTo: .footnote), mono: true))
                .tracking(5)
                .foregroundStyle(.token(.primary))
            Text("login.tagline", tableName: "Login", bundle: .module)
                .font(.agentre(FontRole(size: 32, weight: .bold, relativeTo: .largeTitle)))
                .foregroundStyle(.token(.ink))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var bottom: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isEditingServer {
                serverEditor
            } else {
                server
            }
            signInButton
        }
    }

    /// 服务器行：地球图标、等宽主机名、展开指示，整行是一个按钮——点开即改（规格「07 登录」）。
    @ViewBuilder private var server: some View {
        Button {
            draftAddress = flow.serverAddress.url.absoluteString
            draftIsInvalid = false
            isEditingServer = true
        } label: {
            HStack(spacing: 10) {
                Image(.globe)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .foregroundStyle(.token(.ink3))
                    .accessibilityHidden(true)
                Text(verbatim: flow.serverAddress.hostOnly)
                    .font(.agentre(FontRole(size: 13, relativeTo: .subheadline), mono: true))
                    .foregroundStyle(.token(.ink2))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(.chevronRight)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .foregroundStyle(.token(.ink3))
                    .accessibilityHidden(true)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .background(.token(.surface), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.token(.line)))
        }
        .hitTarget()
        .disabled(isAwaiting)
    }

    @ViewBuilder private var serverEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            AddressField(text: $draftAddress, onSubmit: save)
            if draftIsInvalid {
                Label {
                    Text("login.server.invalid", tableName: "Login", bundle: .module)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.token(.coral))
                }
                .font(.agentre(.footnote))
                .foregroundStyle(.token(.ink2))
            }
            HStack(spacing: 8) {
                Spacer()
                Button {
                    isEditingServer = false
                } label: {
                    Text("login.server.cancel", tableName: "Login", bundle: .module)
                        .font(.agentre(.body))
                        .foregroundStyle(.token(.ink2))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
                Button(action: save) {
                    Text("login.server.save", tableName: "Login", bundle: .module)
                        .font(.agentre(.body, weight: .semibold))
                        .foregroundStyle(.token(.primary))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
                // 等待授权期间地址不可改（设备流在发起时的服务器上换令牌）。
                .disabled(isAwaiting)
            }
        }
        .padding(16)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var outcome: some View {
        if isOffline {
            // 本机没网：如实说是离线，登录点不动——而不是让人点下去再读到「连不上服务器」。
            Label {
                Text("login.deviceOffline", tableName: "Login", bundle: .module)
                    .foregroundStyle(.token(.ink))
            } icon: {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.token(.ink2))
            }
            .font(.agentre(.callout))
            .padding(.bottom, 14)
        } else {
            outcomeStatus
        }
    }

    @ViewBuilder private var outcomeStatus: some View {
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
                .foregroundStyle(.token(.ink))
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.token(.coral))
        }
        .font(.agentre(.callout))
        .padding(.bottom, 14)
    }

    private var signInButton: some View {
        Button {
            Task { await flow.signIn() }
        } label: {
            HStack(spacing: 9) {
                if isAwaiting {
                    ProgressView()
                        .tint(.token(.primaryInk))
                } else {
                    Image(.externalLink)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                Text(signInLabelKey, tableName: "Login", bundle: .module)
            }
            .font(.agentre(FontRole(size: 16, weight: .semibold, relativeTo: .headline)))
            .foregroundStyle(.token(.primaryInk))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.token(.primary), in: Capsule())
            .opacity(isAwaiting || isOffline ? 0.7 : 1)
        }
        .hitTarget()
        .disabled(isAwaiting || isOffline)
    }

    private var signInLabelKey: LocalizedStringKey {
        if isAwaiting { return "login.awaiting" }
        return flow.state == .idle ? "login.signIn" : "login.signIn.again"
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
