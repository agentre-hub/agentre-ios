import AgentreDomain
import Foundation

/// 「我」页的账号端点（agentre-server/internal/api/auth/auth.go 的 /v1/auth/me，
/// device/device.go 的 /v1/devices 与 /v1/oauth/token/revoke）。三者都在
/// SessionOrDeviceAuth 那组，经 `AuthorizedTransport` 带设备令牌调用。
///
/// 失败只以类型化的错误交出去：服务端正文里的 msg 从不被读出，更不会被带到界面上。
public struct AccountClient: AccountService {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public func profile(server: ServerAddress) async throws -> AccountProfile {
        let response = try await transport.send(HTTPRequest(method: "GET", url: server.endpoint("/v1/auth/me")))
        guard response.isSuccess else { throw AuthError.unexpectedResponse(status: response.status) }
        let body = try CagoEnvelope.decodeData(MeResponse.self, from: response)
        return AccountProfile(
            userID: body.userId, email: body.email ?? "", displayName: body.displayName ?? "", githubLogin: body.githubLogin ?? ""
        )
    }

    public func devices(server: ServerAddress) async throws -> [AuthorizedDevice] {
        let response = try await transport.send(HTTPRequest(method: "GET", url: server.endpoint("/v1/devices")))
        guard response.isSuccess else { throw AuthError.unexpectedResponse(status: response.status) }
        return try CagoEnvelope.decodeData(DevicesResponse.self, from: response).devices.map(\.device)
    }

    public func revoke(deviceID: Int64, server: ServerAddress) async throws {
        let request = try HTTPRequest.postJSON(server.endpoint("/v1/oauth/token/revoke"), RevokeBody(deviceId: deviceID))
        let response = try await transport.send(request)
        switch response.status {
        case 200..<300: return
        // 以设备令牌调用时服务端只允许撤销本机（device_ctr.Revoke）。
        case 403: throw AccountError.revokeRefused
        default: throw AuthError.unexpectedResponse(status: response.status)
        }
    }
}

// 与服务端 JSON 的字段一一对应；蛇形命名由 CagoEnvelope 的编解码器统一转换。
private struct MeResponse: Decodable {
    let userId: Int64
    let email: String?
    let displayName: String?
    let githubLogin: String?
}

private struct DevicesResponse: Decodable {
    let devices: [DeviceItem]
}

private struct DeviceItem: Decodable {
    let id: Int64
    let name: String?
    let displayName: String?
    let kind: String?
    let platform: String?
    let fingerprint: String?
    let lastSeenAt: Int64?
    let online: Bool?
    let isThisDevice: Bool?

    var device: AuthorizedDevice {
        AuthorizedDevice(
            id: id, name: name ?? "", displayName: displayName ?? "", kind: kind ?? "", platform: platform ?? "",
            fingerprint: fingerprint ?? "", lastSeenAt: lastSeenAt ?? 0, online: online ?? false, isThisDevice: isThisDevice ?? false
        )
    }
}

private struct RevokeBody: Encodable {
    let deviceId: Int64
}
