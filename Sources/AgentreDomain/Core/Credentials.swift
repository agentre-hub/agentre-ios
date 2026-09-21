import Foundation

/// 本设备的指纹：首次在本机随机生成、此后持久保存的值。不用系统的厂商标识——
/// 它在重装后会变，而这枚指纹是逐通道握手出示的身份，也是本机发起的对话上的来源标注。
public struct DeviceFingerprint: Sendable, Hashable {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    /// 32 字节随机数的小写十六进制（64 字符，落在服务端 8…128 的长度约束内）。
    public static func generate() -> DeviceFingerprint {
        var generator = SystemRandomNumberGenerator()
        let hex = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
        return DeviceFingerprint(value: hex.joined())
    }
}

/// 服务端签发的一对令牌（设备流成功或刷新成功）。
public struct TokenGrant: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresIn: Duration
    public var refreshExpiresIn: Duration

    public init(accessToken: String, refreshToken: String, expiresIn: Duration, refreshExpiresIn: Duration) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.refreshExpiresIn = refreshExpiresIn
    }
}

/// 已登录设备在钥匙串里的凭据。
public struct Credentials: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String
    public var accessTokenExpiresAt: Date
    public var refreshTokenExpiresAt: Date
    public var deviceID: Int64

    public init(accessToken: String, refreshToken: String, accessTokenExpiresAt: Date, refreshTokenExpiresAt: Date, deviceID: Int64) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.deviceID = deviceID
    }

    public init(grant: TokenGrant, deviceID: Int64, issuedAt now: Date) {
        self.init(
            accessToken: grant.accessToken,
            refreshToken: grant.refreshToken,
            accessTokenExpiresAt: now.addingTimeInterval(grant.expiresIn.seconds),
            refreshTokenExpiresAt: now.addingTimeInterval(grant.refreshExpiresIn.seconds),
            deviceID: deviceID
        )
    }

    /// 刷新后的凭据：设备不变，令牌与到期时间换新。
    public func refreshed(with grant: TokenGrant, at now: Date) -> Credentials {
        Credentials(grant: grant, deviceID: deviceID, issuedAt: now)
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (whole, fraction) = components
        return TimeInterval(whole) + TimeInterval(fraction) / 1e18
    }
}
