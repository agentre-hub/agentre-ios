import Foundation

/// 当前访问令牌的唯一出处，也是刷新的唯一执行者：同一时刻只进行一次刷新，
/// 刷新期间到来的其它调用方等同一次结果。刷新被拒即登出。
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

    public func accessToken() throws -> String {
        guard let current = try credentials.loadCredentials() else { throw AuthError.signedOut }
        return current.accessToken
    }

    /// 离到期不足这么久就当作已过期：中继的连接与逐通道握手没有 401 可等（服务端拒绝升级、
    /// 对端核验不过都只是连不上），只能在交出之前按到期时刻判断。
    static let expiryMargin: TimeInterval = 60

    /// 交出一枚没过期的令牌：已过期（或即将过期）就先刷新——同样同一时刻只进行一次，
    /// 刷新被拒同样登出。中继连接与逐通道握手用它；REST 仍是遇 401 再刷新。
    public func unexpiredAccessToken() async throws -> String {
        if let inFlight { return try await inFlight.value }
        guard let current = try credentials.loadCredentials() else { throw AuthError.signedOut }
        guard current.accessTokenExpiresAt.timeIntervalSince(now()) <= Self.expiryMargin else { return current.accessToken }
        return try await refreshedToken(replacing: current.accessToken)
    }

    /// 调用方拿着 `staleToken` 被拒（401）后来换新令牌。若令牌已被别人换过，直接给当前的；
    /// 若正有一次刷新在进行，等它的结果；否则由本次调用发起唯一那次刷新。
    public func refreshedToken(replacing staleToken: String) async throws -> String {
        if let inFlight { return try await inFlight.value }
        guard let current = try credentials.loadCredentials() else { throw AuthError.signedOut }
        guard current.accessToken == staleToken else { return current.accessToken }

        let task = Task { try await refresh(current) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func refresh(_ current: Credentials) async throws -> String {
        do {
            let grant = try await refresher.refresh(refreshToken: current.refreshToken, server: server())
            let renewed = current.refreshed(with: grant, at: now())
            try credentials.saveCredentials(renewed)
            return renewed.accessToken
        } catch AuthError.refreshRejected {
            await onRejected()
            throw AuthError.refreshRejected
        }
    }
}
