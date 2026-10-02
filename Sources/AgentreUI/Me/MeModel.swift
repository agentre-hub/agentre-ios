import AgentreDomain
import Observation

/// 「我」页的状态：账号、服务器地址、已授权设备、语言与外观、退出登录。
/// 失败只以事实（`FailureFact`）留在这里，错误对象本身不越过这一层。
@MainActor
@Observable
public final class MeModel {
    public private(set) var profile: AccountProfile?
    public private(set) var devices: [AuthorizedDevice] = []
    /// 最近一次操作的失败，已解析成事实；成功一次即清掉。
    public private(set) var failure: FailureFact?
    public private(set) var serverAddress: ServerAddress
    /// 应用根视图据此施加 `.displayPreferences(_:)`。
    public private(set) var preferences: DisplayPreferences
    /// 「关于」一行显示的版本号（`MARKETING_VERSION (CURRENT_PROJECT_VERSION)`），装配层从 Bundle 读出后传入。
    public let version: String

    @ObservationIgnored private let account: any AccountService
    @ObservationIgnored private let servers: any ServerAddressStore
    @ObservationIgnored private let preferenceStore: any DisplayPreferencesStore
    @ObservationIgnored private let signOutAction: SignOut

    public init(
        account: any AccountService, servers: any ServerAddressStore, preferences: any DisplayPreferencesStore, signOut: SignOut,
        version: String = ""
    ) {
        self.account = account
        self.servers = servers
        self.preferenceStore = preferences
        self.signOutAction = signOut
        self.serverAddress = servers.load()
        self.preferences = preferences.load()
        self.version = version
    }

    /// 换账号时作废在途的读取：登出前发出的请求晚到，不把上一个账号写回来。
    @ObservationIgnored private var accountGeneration = 0

    /// 读账号信息与设备列表。读不到的那一格保留已有的值，失败呈现为事实。
    public func load() async {
        let generation = accountGeneration
        let server = servers.load()
        serverAddress = server
        async let profileResult = capture { try await self.account.profile(server: server) }
        async let devicesResult = capture { try await self.account.devices(server: server) }
        let (profileOutcome, devicesOutcome) = await (profileResult, devicesResult)
        guard generation == accountGeneration else { return }

        var facts: [FailureFact] = []
        switch profileOutcome {
        case .success(let value): profile = value
        case .failure(let error): FailureFact(presenting: error).map { facts.append($0) }
        }
        switch devicesOutcome {
        case .success(let value): devices = value
        case .failure(let error): FailureFact(presenting: error).map { facts.append($0) }
        }
        failure = facts.first
    }

    /// 改服务器地址。不合法时不改、返回 false。换到另一台服务器即退出登录：
    /// 手里的令牌与本地会话属于原来那台服务器上的账号，不能带过去。退出登录就是撤销本机（决策 22），
    /// 所以先在原来那台服务器上撤销这台设备再换地址；撤销不成同样不拦。
    public func setServerAddress(_ text: String) async -> Bool {
        guard let address = ServerAddress(string: text) else { return false }
        guard address != serverAddress else { return true }
        _ = try? await account.revoke(deviceID: 0, server: serverAddress)
        servers.save(address)
        serverAddress = address
        await signOutAction.run()
        return true
    }

    /// 撤销一台设备。撤销的是本机就是退出登录（决策 22，与底部「退出登录」同一个动作）；
    /// 撤销别的设备则把它从列表里拿掉。
    public func revoke(_ device: AuthorizedDevice) async {
        guard !device.isThisDevice else {
            await signOut()
            return
        }
        do {
            try await account.revoke(deviceID: device.id, server: serverAddress)
        } catch {
            failure = FailureFact(presenting: error)
            return
        }
        failure = nil
        devices.removeAll { $0.id == device.id }
    }

    public func setLanguage(_ language: DisplayLanguage) {
        preferences.language = language
        preferenceStore.save(preferences)
    }

    public func setAppearance(_ appearance: DisplayAppearance) {
        preferences.appearance = appearance
        preferenceStore.save(preferences)
    }

    /// 退出登录就是撤销本机（决策 22）：先请服务端撤销这台设备再清本地。撤销的目标传 0——
    /// 不必先载入过设备列表才知道自己的设备 id，服务端把 0 解成调用方自己（device_ctr.Revoke）。
    /// 撤销失败（离线、服务端不可达）不拦这一步：本地照样清空、回到登录屏。
    public func signOut() async {
        _ = try? await account.revoke(deviceID: 0, server: serverAddress)
        await signOutAction.run()
    }

    /// 登出了：上一个账号的资料、设备与失败都不再属于此后登录的那一个。显示偏好与服务器地址是这台设备的，留着。
    public func forgetAccount() {
        accountGeneration += 1
        profile = nil
        devices = []
        failure = nil
    }
}

private func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
