import Foundation

/// 设备流的两步：发起授权、轮询取令牌（RFC 8628，device_kind = mobile）。
public protocol DeviceAuthorizing: Sendable {
    func authorize(fingerprint: DeviceFingerprint, server: ServerAddress) async throws -> DeviceAuthorization
    func pollToken(deviceCode: String, server: ServerAddress) async throws -> DeviceTokenPoll
}

/// 以刷新令牌换一对新令牌。服务端拒绝时抛 `AuthError.refreshRejected`；
/// 其它失败（断网、5xx）抛别的错误，不等于登出。
public protocol TokenRefreshing: Sendable {
    func refresh(refreshToken: String, server: ServerAddress) async throws -> TokenGrant
}

/// 凭据的持久化：令牌与设备指纹都只在钥匙串里。
public protocol CredentialStore: Sendable {
    func loadCredentials() throws -> Credentials?
    func saveCredentials(_ credentials: Credentials) throws
    /// 登出只清令牌；设备指纹留下，它是这台设备此后一直出示的身份。
    func clearCredentials() throws
    /// 取本设备的指纹；首次调用时生成并持久保存。
    func deviceFingerprint() throws -> DeviceFingerprint
}

/// 当前服务器地址的持久化（不是凭据，不进钥匙串）。
public protocol ServerAddressStore: Sendable {
    func load() -> ServerAddress
    func save(_ address: ServerAddress)
}

/// 打开设备流的验证地址（系统浏览器）。
public protocol VerificationOpening: Sendable {
    @MainActor func open(_ url: URL)
}

/// 轮询间的等待；测试注入立即返回的实现。
public protocol Sleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public enum AuthError: Error, Equatable, Sendable {
    /// 刷新令牌被服务端拒绝：视为登出。
    case refreshRejected
    /// 当前没有已登录的凭据。
    case signedOut
    /// 服务端回了一个客户端认不出的应答。
    case unexpectedResponse(status: Int)
}
