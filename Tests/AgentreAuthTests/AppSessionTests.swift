import AgentreDomain
import Foundation
import Testing

@MainActor
struct AppSessionTests {
    static let credentials = Credentials(grant: .sample, deviceID: 7, issuedAt: Date(timeIntervalSince1970: 0))

    @Test("钥匙串里已有凭据：冷启动直接进入登录态")
    func restoresSignedIn() {
        let session = AppSession(credentials: InMemoryCredentialStore(credentials: Self.credentials))
        #expect(session.phase == .signedIn)
    }

    @Test("没有凭据：停在登录屏")
    func startsSignedOut() {
        let session = AppSession(credentials: InMemoryCredentialStore())
        #expect(session.phase == .signedOut)
    }

    @Test("登出清掉令牌，设备指纹留下")
    func signOutKeepsFingerprint() throws {
        let fingerprint = DeviceFingerprint(value: "fp-0123456789")
        let store = InMemoryCredentialStore(credentials: Self.credentials, fingerprint: fingerprint)
        let session = AppSession(credentials: store)

        session.signOut()

        #expect(session.phase == .signedOut)
        #expect(store.stored == nil)
        #expect(try store.deviceFingerprint() == fingerprint)
    }
}
