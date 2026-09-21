import AgentreDomain
import SwiftUI

/// 按登录态在登录屏与三标签骨架之间切换。
public struct RootView<Login: View, Shell: View>: View {
    private let session: AppSession
    private let login: Login
    private let shell: Shell

    public init(session: AppSession, @ViewBuilder login: () -> Login, @ViewBuilder shell: () -> Shell) {
        self.session = session
        self.login = login()
        self.shell = shell()
    }

    public var body: some View {
        switch session.phase {
        case .signedOut: login
        case .signedIn: shell
        }
    }
}
