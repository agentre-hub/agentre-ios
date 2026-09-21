import Foundation

/// 设备流发起后服务端给出的授权信息。
public struct DeviceAuthorization: Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    /// 带确认码的验证地址：直接打开它，用户不必手输确认码。
    public var verificationURIComplete: URL
    public var interval: Duration
    public var expiresIn: Duration

    public init(deviceCode: String, userCode: String, verificationURIComplete: URL, interval: Duration, expiresIn: Duration) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURIComplete = verificationURIComplete
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

/// 一次轮询的结果（RFC 8628 §3.5）。
public enum DeviceTokenPoll: Sendable, Equatable {
    /// 用户尚未确认：按原间隔继续。
    case pending
    /// 轮询过快：间隔加 5 秒后继续。不是收场。
    case slowDown
    case expired
    case denied
    case authorized(TokenGrant, deviceID: Int64)
}
