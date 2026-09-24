import Foundation

/// 当前访问令牌的唯一出处，也是刷新的唯一执行者：同一时刻只进行一次刷新，
/// 刷新期间到来的其它调用方等同一次结果。刷新被拒即登出；登出一开始（`retire()`）这份登录就不再刷新。
public actor AccessTokenProvider {
    private let credentials: CredentialStore
    private let refresher: TokenRefreshing
    private let server: @Sendable () -> ServerAddress
    private let now: @Sendable () -> Date
    private let onRejected: @Sendable () async -> Void

    public init(
        credentials: CredentialStore,
        refresher: TokenRefreshing,
        server: @escaping @Sendable () -> ServerAddress,
        now: @escaping @Sendable () -> Date = Date.init,
        onRejected: @escaping @Sendable () async -> Void
    ) {
        self.credentials = credentials
        self.refresher = refresher
        self.server = server
        self.now = now
        self.onRejected = onRejected
    }

    private var inFlight: Task<String, any Error>?
    /// 已开始登出的那份登录（按刷新令牌认）。登出先拆登录态、清库，最后才清钥匙串：
    /// 这段时间里令牌还躺在钥匙串里，但已不作数（撤销本机后服务端整条刷新链作废）。
    private var retiredRefreshToken: String?

    /// 登出开始了：此刻存着的这份登录不再交出令牌，遇 401 也不刷新——拆登录态途中还在路上的请求
    /// 不拿作废的刷新令牌去换新、不因被拒再登出一次。之后登录的另一份照常。
    public func retire() {
        retiredRefreshToken = (try? credentials.loadCredentials())?.refreshToken
    }

    public func accessToken() throws -> String {
        try liveCredentials().accessToken
    }

    /// 离到期不足这么久就当作已过期：中继的连接与逐通道握手没有 401 可等（服务端拒绝升级、
    /// 对端核验不过都只是连不上），只能在交出之前按到期时刻判断。
    static let expiryMargin: TimeInterval = 60

    /// 交出一枚没过期的令牌：已过期（或即将过期）就先刷新——同样同一时刻只进行一次，
    /// 刷新被拒同样登出。中继连接与逐通道握手用它；REST 仍是遇 401 再刷新。
    public func unexpiredAccessToken() async throws -> String {
        if let inFlight { return try await inFlight.value }
        let current = try liveCredentials()
        guard current.accessTokenExpiresAt.timeIntervalSince(now()) <= Self.expiryMargin else { return current.accessToken }
        return try await refreshedToken(replacing: current.accessToken)
    }

    /// 调用方拿着 `staleToken` 被拒（401）后来换新令牌。若令牌已被别人换过，直接给当前的；
    /// 若正有一次刷新在进行，等它的结果；否则由本次调用发起唯一那次刷新。
    public func refreshedToken(replacing staleToken: String) async throws -> String {
        if let inFlight { return try await inFlight.value }
        let current = try liveCredentials()
        guard current.accessToken == staleToken else { return current.accessToken }

        let task = Task { try await refresh(current) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// 刷新在路上时凭据可能已被登出清掉（或登出已开始）、或换成了另一次登录的：那时这次刷新的结果（成败都是）
    /// 属于已经不在的那份登录，不落库、也不据它登出——否则登出后凭据会复活，或把新登录登出。
    private func refresh(_ current: Credentials) async throws -> String {
        do {
            let grant = try await refresher.refresh(refreshToken: current.refreshToken, server: server())
            if let superseding = try supersedingCredentials(of: current) { return superseding.accessToken }
            let renewed = current.refreshed(with: grant, at: now())
            try credentials.saveCredentials(renewed)
            return renewed.accessToken
        } catch AuthError.refreshRejected {
            if let superseding = try supersedingCredentials(of: current) { return superseding.accessToken }
            await onRejected()
            throw AuthError.refreshRejected
        }
    }

    /// 存着的已不是发起刷新时那一份：换成了别的登录就交出它；已登出（或登出已开始）抛 `signedOut`；仍是同一份为 nil。
    private func supersedingCredentials(of current: Credentials) throws -> Credentials? {
        let stored = try liveCredentials()
        return stored.refreshToken == current.refreshToken ? nil : stored
    }

    /// 存着的、仍作数的凭据；没有或登出已开始即 `signedOut`。
    private func liveCredentials() throws -> Credentials {
        guard let stored = try credentials.loadCredentials(), stored.refreshToken != retiredRefreshToken else {
            throw AuthError.signedOut
        }
        return stored
    }
}
