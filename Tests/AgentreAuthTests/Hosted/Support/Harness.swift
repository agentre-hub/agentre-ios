@testable import Agentre
import AgentreDomain
import AgentreStore
import Foundation
import Security

/// 一台装着伪服务端、伪中继、真实钥匙串（独立 service）与真实本地库目录的 App。
/// 同一个 Harness 上可以反复 `environment()`：那就是冷启动——同一个钥匙串、同一个库目录。
@MainActor
final class Harness {
    static let serverURL = "https://server.test"

    let server = FakeServer()
    let machine: FakeMachine
    let relay: FakeRelay
    let directory: TemporaryDirectory
    let service = "com.agentrehub.agentre.hostedtests.\(UUID().uuidString)"
    let opener = RecordingOpener()
    let servers = MemoryServerAddressStore(ServerAddress(string: Harness.serverURL)!)

    init(machine fingerprint: String = "machine-a", machineName: String = "mac-studio", kind: String = "agentred") throws {
        machine = FakeMachine(fingerprint: fingerprint)
        relay = FakeRelay([machine])
        directory = try TemporaryDirectory()
        server.route("GET /v1/devices", """
        {"devices":[{"id":10,"name":"\(machineName)","display_name":"","kind":"\(kind)","platform":"linux","version":"1.0",\
        "fingerprint":"\(fingerprint)","last_seen_at":1700000000000,"online":true},\
        {"id":7,"name":"iPhone","display_name":"","kind":"mobile","platform":"ios","version":"0.1.0",\
        "fingerprint":"phone","last_seen_at":0,"online":true,"is_this_device":true}]}
        """)
    }

    var credentials: KeychainCredentialStore { KeychainCredentialStore(service: service) }

    var storeDirectory: URL { directory.url.appending(path: "store", directoryHint: .isDirectory) }

    func dependencies() -> AppDependencies {
        AppDependencies(
            credentials: credentials, servers: servers, preferences: MemoryPreferencesStore(),
            http: server, relayDialer: relay, storeDirectory: storeDirectory, opener: opener,
            loginSleeper: InstantSleeper(), relaySleeper: TaskSleeper(), deviceName: "Test iPhone", version: "0.1.0"
        )
    }

    func environment() throws -> AppEnvironment {
        try AppEnvironment(dependencies())
    }

    /// 已登录：钥匙串里放一对令牌（跳过设备流）。
    func signIn(accessToken: String = "at-1") throws {
        try credentials.saveCredentials(Credentials(
            accessToken: accessToken, refreshToken: "rt-1",
            accessTokenExpiresAt: Date().addingTimeInterval(3_600), refreshTokenExpiresAt: Date().addingTimeInterval(86_400),
            deviceID: 7
        ))
    }

    func cleanUp() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}
