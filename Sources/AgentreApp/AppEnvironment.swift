import AgentreDomain
import AgentreREST
import AgentreStore
import Foundation
import UIKit

/// 装配层：全应用唯一知道全部具体实现的地方。
@MainActor
final class AppEnvironment {
    let session: AppSession
    let loginFlow: LoginFlow
    /// 带设备令牌、遇 401 单次刷新后重试的传输；后续的 REST 客户端都经它发请求。
    let authorizedTransport: AuthorizedTransport

    init() {
        let credentials = KeychainCredentialStore(service: "com.agentrehub.agentre")
        let servers = UserDefaultsServerAddressStore()
        let transport = URLSessionTransport()
        let bundle = Bundle.main
        let deviceAuth = DeviceAuthClient(
            transport: transport,
            platform: "ios",
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            deviceName: UIDevice.current.name
        )
        let session = AppSession(credentials: credentials)
        self.session = session
        loginFlow = LoginFlow(
            session: session,
            deviceAuth: deviceAuth,
            credentials: credentials,
            servers: servers,
            opener: SystemVerificationOpener(),
            sleeper: TaskSleeper()
        )
        let tokens = AccessTokenProvider(
            credentials: credentials,
            refresher: deviceAuth,
            server: { servers.load() },
            onRejected: { await session.signOut() }
        )
        authorizedTransport = AuthorizedTransport(inner: transport, tokens: tokens)
    }
}

/// 在系统浏览器里打开设备流的验证地址。
struct SystemVerificationOpener: VerificationOpening {
    @MainActor func open(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
