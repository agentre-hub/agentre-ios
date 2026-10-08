import AgentreDomain
import Foundation

/// agentre-server 设备流端点的客户端（agentre-server/internal/api/device/device.go）。
public struct DeviceAuthClient: DeviceAuthorizing, TokenRefreshing {
    private let transport: HTTPTransport
    private let platform: String
    private let version: String
    private let deviceName: String

    public init(transport: HTTPTransport, platform: String, version: String, deviceName: String) {
        self.transport = transport
        self.platform = platform
        self.version = version
        self.deviceName = deviceName
    }

    public func authorize(fingerprint: DeviceFingerprint, server: ServerAddress) async throws -> DeviceAuthorization {
        let request = try HTTPRequest.postJSON(server.endpoint("/v1/oauth/device/authorize"), AuthorizeBody(
            deviceKind: "mobile", fingerprint: fingerprint.value, platform: platform, version: version, name: deviceName
        ))
        let response = try await transport.send(request)
        guard response.isSuccess else { throw AuthError.unexpectedResponse(status: response.status) }
        let body = try CagoEnvelope.decodeData(AuthorizeResponse.self, from: response)
        guard !body.deviceCode.isEmpty, body.expiresIn > 0,
              let url = URL(string: body.verificationUriComplete), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { throw AuthError.unexpectedResponse(status: response.status) }
        return DeviceAuthorization(
            deviceCode: body.deviceCode, userCode: body.userCode, verificationURIComplete: url,
            interval: .seconds(body.interval), expiresIn: .seconds(body.expiresIn)
        )
    }

    public func pollToken(deviceCode: String, server: ServerAddress) async throws -> DeviceTokenPoll {
        let request = try HTTPRequest.postJSON(server.endpoint("/v1/oauth/device/token"), TokenBody(
            grantType: "urn:ietf:params:oauth:grant-type:device_code", deviceCode: deviceCode
        ))
        let response = try await transport.send(request)
        guard response.isSuccess else {
            switch CagoEnvelope.oauthError(in: response) {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "expired_token": return .expired
            case "access_denied": return .denied
            default: throw AuthError.unexpectedResponse(status: response.status)
            }
        }
        let body = try CagoEnvelope.decodeData(TokenResponse.self, from: response)
        guard let deviceID = body.deviceId else { throw AuthError.unexpectedResponse(status: response.status) }
        return .authorized(try body.grant(status: response.status), deviceID: deviceID)
    }

    public func refresh(refreshToken: String, server: ServerAddress) async throws -> TokenGrant {
        let request = try HTTPRequest.postJSON(server.endpoint("/v1/oauth/token/refresh"), RefreshBody(refreshToken: refreshToken))
        let response = try await transport.send(request)
        if response.isSuccess {
            return try CagoEnvelope.decodeData(TokenResponse.self, from: response).grant(status: response.status)
        }
        guard Self.isCredentialRejection(response) else { throw AuthError.unexpectedResponse(status: response.status) }
        throw AuthError.refreshRejected
    }

    /// 服务端说这份凭据不作数了（与桌面端 server_svc.credentialRejection 同一判据）：判据是 OAuth 的
    /// error 码——服务端把 invalid_grant 映射成 HTTP 400，单看状态码分不出它和被反代改坏的请求；
    /// 401 / 403 留给换了鉴权前置的部署形态。限流、超时等其它失败都不是，不能据此登出。
    private static func isCredentialRejection(_ response: HTTPResponse) -> Bool {
        switch CagoEnvelope.oauthError(in: response) {
        case "invalid_grant", "invalid_client": true
        default: response.status == 401 || response.status == 403
        }
    }
}

// 与服务端 JSON 的字段一一对应；蛇形命名由 CagoEnvelope 的编解码器统一转换。
private struct AuthorizeBody: Encodable {
    let deviceKind: String
    let fingerprint: String
    let platform: String
    let version: String
    let name: String
}

private struct AuthorizeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUriComplete: String
    let interval: Int
    let expiresIn: Int
}

private struct TokenBody: Encodable {
    let grantType: String
    let deviceCode: String
}

private struct RefreshBody: Encodable {
    let refreshToken: String
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let refreshExpiresIn: Int
    /// 刷新应答不带它：设备不变，由调用方沿用。
    let deviceId: Int64?

    func grant(status: Int) throws -> TokenGrant {
        guard !accessToken.isEmpty, !refreshToken.isEmpty, expiresIn > 0, refreshExpiresIn > 0 else {
            throw AuthError.unexpectedResponse(status: status)
        }
        return TokenGrant(
            accessToken: accessToken, refreshToken: refreshToken,
            expiresIn: .seconds(expiresIn), refreshExpiresIn: .seconds(refreshExpiresIn)
        )
    }
}
