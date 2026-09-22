import AgentreDomain
import Foundation

/// 机器名册：`GET /v1/devices`（agentre-server/internal/api/device/device.go 的 ListDevices）。
/// 在线态是服务端读到的中继在线态；名册里只留承载会话的机器（桌面端与 agentred）。
public struct MachineRosterClient: MachineRoster {
    /// 会承载会话、能经 `machine:` 通道问话的设备种类（device_entity.KindDesktop / KindAgentred）。
    static let machineKinds: Set<String> = ["desktop", "agentred"]

    private let transport: HTTPTransport
    private let server: ServerAddress

    public init(transport: HTTPTransport, server: ServerAddress) {
        self.transport = transport
        self.server = server
    }

    public func machines() async throws -> [Machine] {
        let response = try await transport.send(HTTPRequest(method: "GET", url: server.endpoint("/v1/devices")))
        guard response.isSuccess else { throw AuthError.unexpectedResponse(status: response.status) }
        return try CagoEnvelope.decodeData(ListedDevices.self, from: response).devices
            .filter { Self.machineKinds.contains($0.kind ?? "") }
            .map(\.machine)
    }
}

private extension ListedDevice {
    var machine: Machine {
        let name = name ?? ""
        let displayName = displayName ?? ""
        return Machine(
            id: id, fingerprint: fingerprint ?? "", name: displayName.isEmpty ? name : displayName, kind: kind ?? "",
            platform: platform ?? "", version: version ?? "", online: online ?? false, lastSeenAt: lastSeenAt ?? 0
        )
    }
}
