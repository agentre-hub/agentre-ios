import AgentreDomain
import Observation

/// 「我」页的状态：账号、服务器地址、已授权设备、语言与外观、退出登录。
/// 失败只以事实（`FailureFact`）留在这里，错误对象本身不越过这一层。
@MainActor
@Observable
public final class MeModel {
    public private(set) var profile: AccountProfile?
    /// 已授权设备；一次都没取到时为 nil——条数不知道，不是零（本机自己就是一台）。
    public private(set) var devices: [AuthorizedDevice]?
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
    @ObservationIgnored private let sleeper: any Sleeping
    @ObservationIgnored private let revokeDeadline: Duration

    /// - Parameters:
    ///   - sleeper: 撤销本机的等待期限按它计时。
    ///   - revokeDeadline: 退出登录（含换服务器）时撤销本机最多等多久；到期不等，照样清本地。
    public init(
        account: any AccountService, servers: any ServerAddressStore, preferences: any DisplayPreferencesStore, signOut: SignOut,
        version: String = "", sleeper: any Sleeping = TaskSleeper(), revokeDeadline: Duration = .seconds(5)
    ) {
        self.account = account
        self.servers = servers
        self.preferenceStore = preferences
        self.signOutAction = signOut
        self.sleeper = sleeper
        self.revokeDeadline = revokeDeadline
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

    /// 改服务器地址。不合法时（或退出登录已在途时）不改、返回 false。换到另一台服务器即退出登录：
    /// 手里的令牌与本地会话属于原来那台服务器上的账号，不能带过去。退出登录就是撤销本机（决策 22），
    /// 所以先在原来那台服务器上撤销这台设备再换地址；撤销不成、到期不答同样不拦。
    public func setServerAddress(_ text: String) async -> Bool {
        guard let address = ServerAddress(string: text) else { return false }
        guard address != serverAddress else { return true }
        guard !isSigningOut else { return false }
        isSigningOut = true
        defer { isSigningOut = false }
        await revokeThisDevice(on: serverAddress)
        servers.save(address)
        serverAddress = address
        await signOutAction.run()
        return true
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
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        await revokeThisDevice(on: serverAddress)
        await signOutAction.run()
    }

    /// 退出登录（含换服务器）在途：再点一次不再撤销、不再登出一遍——晚到的那一遍会把此后新登录的账号一并登出。
    @ObservationIgnored private var isSigningOut = false

    /// 请服务端撤销本机，最多等 `revokeDeadline`：网络在而服务器不答时请求要等系统一分钟的超时，
    /// 「撤销不成不拦」不能变成让用户干等。到期即撤回这次请求。
    private func revokeThisDevice(on server: ServerAddress) async {
        let account = account
        let sleeper = sleeper
        let deadline = revokeDeadline
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await account.revoke(deviceID: 0, server: server) }
            group.addTask { try? await sleeper.sleep(for: deadline) }
            await group.next()
            group.cancelAll()
        }
    }

    /// 登出了：上一个账号的资料、设备与失败都不再属于此后登录的那一个。显示偏好与服务器地址是这台设备的，留着。
    public func forgetAccount() {
        accountGeneration += 1
        profile = nil
        devices = nil
        failure = nil
    }
}

private func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
