import Foundation
import Observation

/// 应用是否处于登录态。根视图按它在登录屏与三标签骨架之间切换。
@MainActor @Observable
public final class AppSession {
    public enum Phase: Sendable, Equatable {
        case signedOut
        case signedIn
    }

    public private(set) var phase: Phase

    @ObservationIgnored private let credentials: CredentialStore

    public init(credentials: CredentialStore) {
        self.credentials = credentials
        self.phase = (try? credentials.loadCredentials()) == nil ? .signedOut : .signedIn
    }

    /// 设备流成功：凭据先落钥匙串，再进入登录态。落不下就不算登录成功。
    public func signIn(with newCredentials: Credentials) throws {
        try credentials.saveCredentials(newCredentials)
        phase = .signedIn
    }

    /// 登出（含刷新被拒）：清掉令牌、回到登录屏。设备指纹不动。
    public func signOut() {
        try? credentials.clearCredentials()
        phase = .signedOut
    }
}
