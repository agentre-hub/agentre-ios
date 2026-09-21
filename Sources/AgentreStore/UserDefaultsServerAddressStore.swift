import AgentreDomain
import Foundation

/// 服务器地址存在 UserDefaults：它不是凭据。
public struct UserDefaultsServerAddressStore: ServerAddressStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public static let key = "serverAddress"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ServerAddress {
        defaults.string(forKey: Self.key).flatMap(ServerAddress.init(string:)) ?? .production
    }

    public func save(_ address: ServerAddress) {
        defaults.set(address.url.absoluteString, forKey: Self.key)
    }
}
