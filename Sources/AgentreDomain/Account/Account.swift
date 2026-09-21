import Foundation

/// 当前登录的账号（/v1/auth/me）。
public struct AccountProfile: Sendable, Equatable {
    public var userID: Int64
    public var email: String
    public var displayName: String
    public var githubLogin: String

    public init(userID: Int64, email: String, displayName: String, githubLogin: String) {
        self.userID = userID
        self.email = email
        self.displayName = displayName
        self.githubLogin = githubLogin
    }
}

/// 账号下一台已授权的设备。
public struct AuthorizedDevice: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var name: String
    public var displayName: String
    public var kind: String
    public var platform: String
    public var fingerprint: String
    public var lastSeenAt: Int64
    public var online: Bool
    public var isThisDevice: Bool

    public init(
        id: Int64, name: String, displayName: String, kind: String, platform: String, fingerprint: String,
        lastSeenAt: Int64, online: Bool, isThisDevice: Bool
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.platform = platform
        self.fingerprint = fingerprint
        self.lastSeenAt = lastSeenAt
        self.online = online
        self.isThisDevice = isThisDevice
    }

    /// 用户起过备注名就用它，否则用设备自报的名字。
    public var shownName: String { displayName.isEmpty ? name : displayName }
}

extension AccountProfile {
    /// 账号的称呼：显示名，其次 GitHub 登录名，再次邮箱。
    public var shownName: String {
        [displayName, githubLogin, email].first { !$0.isEmpty } ?? ""
    }
}

/// 「我」页要的账号面：账号信息、已授权设备、撤销设备。
public protocol AccountService: Sendable {
    func profile(server: ServerAddress) async throws -> AccountProfile
    func devices(server: ServerAddress) async throws -> [AuthorizedDevice]
    func revoke(deviceID: Int64, server: ServerAddress) async throws
}

public enum AccountError: Error, Equatable, Sendable {
    /// 服务端拒绝撤销这台设备：以设备令牌调用时只能撤销本机，其它设备只能在网页控制台撤销。
    case revokeRefused
}
