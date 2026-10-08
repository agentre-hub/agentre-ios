import AgentreDomain
import AgentreStore
import Foundation
import Security
import Testing

/// 真实钥匙串（模拟器）。每个用例用自己的 service，结束时删干净。
@Suite(.serialized)
struct KeychainCredentialStoreTests {
    let service = "com.agentrehub.agentre.tests.\(UUID().uuidString)"
    static let credentials = Credentials(
        accessToken: "at", refreshToken: "rt",
        accessTokenExpiresAt: Date(timeIntervalSince1970: 1_800_000_900),
        refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_800_086_400), deviceID: 42
    )

    func cleanUp() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }

    @Test("令牌写入后，另一个实例（冷启动）读出同一份；清除后读不到")
    func roundTrip() throws {
        defer { cleanUp() }
        let store = KeychainCredentialStore(service: service)
        #expect(try store.loadCredentials() == nil)

        try store.saveCredentials(Self.credentials)
        #expect(try KeychainCredentialStore(service: service).loadCredentials() == Self.credentials)

        var renewed = Self.credentials
        renewed.accessToken = "at2"
        try store.saveCredentials(renewed)
        #expect(try store.loadCredentials() == renewed)

        try store.clearCredentials()
        #expect(try KeychainCredentialStore(service: service).loadCredentials() == nil)
    }

    @Test("设备指纹首次生成后持久：跨实例不变、登出不变，且是随机值而非厂商标识")
    func fingerprintPersists() throws {
        defer { cleanUp() }
        let first = try KeychainCredentialStore(service: service).deviceFingerprint()
        #expect(first.value.count == 64)
        #expect(first.value.allSatisfy { $0.isHexDigit })

        try KeychainCredentialStore(service: service).saveCredentials(Self.credentials)
        try KeychainCredentialStore(service: service).clearCredentials()
        #expect(try KeychainCredentialStore(service: service).deviceFingerprint() == first)

        let otherService = "\(service).other"
        defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: otherService] as CFDictionary) }
        #expect(try KeychainCredentialStore(service: otherService).deviceFingerprint() != first)
    }

    @Test("每一项都仅本设备可用、不随账号同步")
    func itemsAreThisDeviceOnly() throws {
        defer { cleanUp() }
        let store = KeychainCredentialStore(service: service)
        try store.saveCredentials(Self.credentials)
        _ = try store.deviceFingerprint()

        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary, &result)
        #expect(status == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 2)
        for item in items {
            #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #expect((item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
        }
    }
}
