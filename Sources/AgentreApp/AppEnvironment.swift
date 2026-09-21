import AgentreDomain
import AgentreREST
import AgentreStore
import AgentreUI
import Foundation

/// 装配层：全应用唯一知道全部具体实现的地方。它活得和应用一样长；登录态里才有的那一套
/// （中继连接、各屏的端口与模型）由 `SignedInServices` 承载，登出即拆。
@MainActor
final class AppEnvironment {
    let dependencies: AppDependencies
    let session: AppSession
    let loginFlow: LoginFlow
    /// 手机自有的会话库。登出时由 `SignOut` 清空，不随登录态重建。
    let store: LocalConversationStore
    let signOut: SignOut
    /// 带设备令牌、遇 401 单次刷新后重试的传输；REST 客户端都经它发请求。刷新被拒即登出（清钥匙串与本地库）。
    let transport: AuthorizedTransport
    let tokens: AccessTokenProvider
    /// 「我」页；它的显示偏好在登录屏上也生效，所以跟应用同寿。
    let me: MeModel
    /// 这台设备此刻有没有网络；登录屏与登录态都据它说离线。
    let connectivity: Connectivity
    private(set) var services: SignedInServices?

    init(_ dependencies: AppDependencies) throws {
        self.dependencies = dependencies
        store = try Self.openStore(in: dependencies.storeDirectory)
        let session = AppSession(credentials: dependencies.credentials)
        self.session = session
        let signOut = SignOut(session: session, store: store)
        self.signOut = signOut
        let deviceAuth = DeviceAuthClient(
            transport: dependencies.http, platform: "ios", version: dependencies.version, deviceName: dependencies.deviceName
        )
        loginFlow = LoginFlow(
            session: session, deviceAuth: deviceAuth, credentials: dependencies.credentials, servers: dependencies.servers,
            opener: dependencies.opener, sleeper: dependencies.loginSleeper
        )
        let servers = dependencies.servers
        tokens = AccessTokenProvider(
            credentials: dependencies.credentials, refresher: deviceAuth, server: { servers.load() },
            onRejected: { await signOut.run() }
        )
        transport = AuthorizedTransport(inner: dependencies.http, tokens: tokens)
        me = MeModel(account: AccountClient(transport: transport), servers: servers, preferences: dependencies.preferences, signOut: signOut)
        connectivity = Connectivity(updates: dependencies.networkPath())
    }

    /// 库打不开（文件坏了）时整个目录重建：库里只是机器上那份的副本，机器才是权威。
    private static func openStore(in directory: URL) throws -> LocalConversationStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            return try LocalConversationStore(directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try LocalConversationStore(directory: directory)
        }
    }

    /// 进入登录态：按此刻的服务器地址建好中继连接与各屏的端口，开始连接与跟随。
    @discardableResult
    func startServices() -> SignedInServices {
        if let services { return services }
        let services = SignedInServices(environment: self)
        self.services = services
        services.start()
        return services
    }

    /// 离开登录态（或测试收场）：停掉跟随与中继连接。
    func tearDown() async {
        guard let services else { return }
        await tearDown(services)
    }

    /// 只拆 `ending` 这一套：新的登录态已经建起来时，旧视图晚到的收场不能拆掉新的。
    func tearDown(_ ending: SignedInServices) async {
        if services === ending { services = nil }
        await ending.stop()
    }
}
