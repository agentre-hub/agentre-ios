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

    @ObservationIgnored private let account: any AccountService
    @ObservationIgnored private let servers: any ServerAddressStore
    @ObservationIgnored private let preferenceStore: any DisplayPreferencesStore
    @ObservationIgnored private let signOutAction: SignOut

    public init(account: any AccountService, servers: any ServerAddressStore, preferences: any DisplayPreferencesStore, signOut: SignOut) {
        self.account = account
        self.servers = servers
        self.preferenceStore = preferences
        self.signOutAction = signOut
        self.serverAddress = servers.load()
        self.preferences = preferences.load()
    }

    /// 读账号信息与设备列表。读不到的那一格保留已有的值，失败呈现为事实。
    public func load() async {
        let server = servers.load()
        serverAddress = server
        async let profileResult = capture { try await self.account.profile(server: server) }
        async let devicesResult = capture { try await self.account.devices(server: server) }
        let (profileOutcome, devicesOutcome) = await (profileResult, devicesResult)

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
    /// 手里的令牌与本地会话属于原来那台服务器上的账号，不能带过去。
    public func setServerAddress(_ text: String) async -> Bool {
        guard let address = ServerAddress(string: text) else { return false }
        guard address != serverAddress else { return true }
        servers.save(address)
        serverAddress = address
        await signOutAction.run()
        return true
    }

    /// 撤销一台设备。撤销的是本机即退出登录；撤销别的设备则把它从列表里拿掉。
    public func revoke(_ device: AuthorizedDevice) async {
        do {
            try await account.revoke(deviceID: device.id, server: serverAddress)
        } catch {
            failure = FailureFact(presenting: error)
            return
        }
        failure = nil
        if device.isThisDevice {
            await signOutAction.run()
        } else {
            devices.removeAll { $0.id == device.id }
        }
    }

    public func setLanguage(_ language: DisplayLanguage) {
        preferences.language = language
        preferenceStore.save(preferences)
    }

    public func setAppearance(_ appearance: DisplayAppearance) {
        preferences.appearance = appearance
        preferenceStore.save(preferences)
    }

    public func signOut() async {
        await signOutAction.run()
    }
}

private func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
