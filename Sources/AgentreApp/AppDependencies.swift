import AgentreDomain
import AgentreRelay
import AgentreREST
import AgentreStore
import Foundation
import UIKit

/// 装配层从外界取的一切：真机上是系统实现，宿主测试换成伪服务端、伪中继与临时目录。
struct AppDependencies {
    var credentials: any CredentialStore
    var servers: any ServerAddressStore
    var preferences: any DisplayPreferencesStore
    var http: any HTTPTransport
    var relayDialer: any RelaySocketDialing
    /// 本地会话库所在的目录（应用沙盒内）。
    var storeDirectory: URL
    var opener: any VerificationOpening
    /// 设备流轮询之间的等待。
    var loginSleeper: any Sleeping
    /// 中继的重拨退让与调用兜底期限：必须是真实时间。
    var relaySleeper: any Sleeping
    var deviceName: String
    /// 设备流上报的软件版本（`CFBundleShortVersionString`，即 `MARKETING_VERSION`）。
    var version: String
    /// 「我」页「关于」一行显示的版本号：`MARKETING_VERSION (CURRENT_PROJECT_VERSION)`（规格「09 我」）。
    var appVersion: String = ""
    /// 网络路径的变化（true = 有网）。真机上是系统网络路径；宿主测试不给时按一直有网。
    var networkPath: @Sendable () -> AsyncStream<Bool> = { AsyncStream { $0.yield(true) } }

    @MainActor
    static func live() -> AppDependencies {
        AppDependencies(
            credentials: KeychainCredentialStore(service: "com.agentrehub.agentre"),
            servers: UserDefaultsServerAddressStore(),
            preferences: UserDefaultsDisplayPreferencesStore(),
            http: URLSessionTransport(),
            relayDialer: URLSessionRelayDialer(),
            storeDirectory: URL.applicationSupportDirectory.appending(path: "Conversations", directoryHint: .isDirectory),
            opener: SystemVerificationOpener(),
            loginSleeper: TaskSleeper(),
            relaySleeper: TaskSleeper(),
            deviceName: UIDevice.current.name,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            appVersion: Self.liveAppVersion(),
            networkPath: { Connectivity.systemPath() }
        )
    }

    /// `MARKETING_VERSION (CURRENT_PROJECT_VERSION)`，两者都来自构建设置（project.yml），
    /// 经 Info.plist 的 `CFBundleShortVersionString` / `CFBundleVersion` 读出。
    private static func liveAppVersion() -> String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !build.isEmpty else { return marketing }
        return "\(marketing) (\(build))"
    }
}

/// 在系统浏览器里打开设备流的验证地址。
struct SystemVerificationOpener: VerificationOpening {
    @MainActor func open(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
