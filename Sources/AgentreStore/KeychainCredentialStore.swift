import AgentreDomain
import Foundation
import Security

/// 钥匙串里的凭据与设备指纹：两项通用密码，同一 service 下以 account 区分。
///
/// 每一项都是 `AfterFirstUnlockThisDeviceOnly`、不可同步——仅本设备可用，不随 iCloud
/// 钥匙串到别的设备，也不进可迁移的备份。它们不写日志：本类型不输出任何内容。
public struct KeychainCredentialStore: CredentialStore {
    public struct KeychainError: Error, Equatable {
        public let status: OSStatus
    }

    private enum Account: String {
        case credentials
        case fingerprint = "device-fingerprint"
    }

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func loadCredentials() throws -> Credentials? {
        guard let data = try read(.credentials) else { return nil }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    public func saveCredentials(_ credentials: Credentials) throws {
        try write(.credentials, JSONEncoder().encode(credentials))
    }

    public func clearCredentials() throws {
        let status = SecItemDelete(query(.credentials) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func deviceFingerprint() throws -> DeviceFingerprint {
        if let data = try read(.fingerprint), let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return DeviceFingerprint(value: value)
        }
        let generated = DeviceFingerprint.generate()
        try write(.fingerprint, Data(generated.value.utf8))
        return generated
    }

    private func query(_ account: Account) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    private func read(_ account: Account) throws -> Data? {
        var lookup = query(account)
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    private func write(_ account: Account, _ data: Data) throws {
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: false,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
