import Foundation

/// `GET /v1/devices` 的应答（agentre-server/internal/api/device/device.go 的 ListDevicesItem）。
/// 「我」页的设备列表与机器名册读的是同一个端点，只有这一份解码：缺哪一格都按空值读，
/// 两处不会一处照常、一处整页失败。蛇形命名由 CagoEnvelope 的解码器统一转换。
struct ListedDevices: Decodable {
    let devices: [ListedDevice]
}

struct ListedDevice: Decodable {
    let id: Int64
    let name: String?
    let displayName: String?
    let kind: String?
    let platform: String?
    let version: String?
    let fingerprint: String?
    let lastSeenAt: Int64?
    let online: Bool?
    let isThisDevice: Bool?
}
