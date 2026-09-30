import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import Foundation
import SwiftUI
import Testing

/// 「我」主页的视图层断言（规格「逐屏视觉契约·09 我」）：逐屏命中区（发现数 = 放置数），
/// 以及屏上读得到的事实。设备列表、服务器编辑、语言与外观的选项分别是各自二级页的断言
/// （`AuthorizedDevicesScreenTests`、`ServerAddressScreenTests`、`PreferenceScreensTests`）。
@MainActor
@Suite("「我」主页")
struct MeScreenTests {
    static let tall = CGSize(width: 390, height: 900)

    static func text(_ key: String) -> String {
        AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Me")
    }

    func loadedModel(account: FakeAccountService = FakeAccountService(), version: String = "0.1.0 (1)") async -> MeModel {
        let model = MeModel(
            account: account, servers: InMemoryServerAddressStore(), preferences: InMemoryDisplayPreferencesStore(),
            signOut: SignOut(session: AppSession(credentials: InMemoryCredentialStore(credentials: signedInCredentials)), store: EmptyStore()),
            version: version
        )
        await model.load()
        return model
    }

    private func view(_ model: MeModel) -> some View {
        NavigationStack { MeView(model: model) { _ in } }
    }

    /// 放置的可点元素：服务器、已授权设备、语言、外观、退出登录，各一枚（关于不可点，不算）。
    static let placedTargets = 5

    @Test("每个可点元素的命中区补满 44×44 且互不重叠；发现的目标数 = 放置的可点元素数")
    func hitTargets() async throws {
        let model = await loadedModel()
        let report = await hitTargetReport(of: view(model), size: Self.tall)
        #expect(report.targets.count == Self.placedTargets, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("载入失败时：失败事实与重试按钮也在命中区清单里")
    func hitTargetsWithFailure() async throws {
        let account = FakeAccountService()
        await account.configure(devices: .failure(URLError(.timedOut)))
        let model = await loadedModel(account: account)
        #expect(model.failure == .timedOut)
        let report = await hitTargetReport(of: view(model), size: Self.tall)
        #expect(report.targets.count == Self.placedTargets + 1, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
        let labels = await HostedScreen(view(model), size: Self.tall).labels().joined(separator: "\n")
        #expect(labels.contains(Self.text("failure.timedOut")), "\(labels)")
    }

    @Test("屏上读得到：账号卡（显示名、邮箱）、主机名、已授权设备条数、语言与外观的当前取值、关于版本、退出登录")
    func facts() async throws {
        let account = FakeAccountService()
        let model = MeModel(
            account: account, servers: InMemoryServerAddressStore(), preferences: InMemoryDisplayPreferencesStore(
                DisplayPreferences(language: .simplifiedChinese, appearance: .dark)
            ),
            signOut: SignOut(session: AppSession(credentials: InMemoryCredentialStore(credentials: signedInCredentials)), store: EmptyStore()),
            version: "0.1.0 (1)"
        )
        await model.load()
        let labels = await HostedScreen(view(model), size: Self.tall).labels().joined(separator: "\n")
        #expect(labels.contains("Ada"))
        #expect(labels.contains("ada@example.com"))
        #expect(labels.contains("app.agentrehub.com"))
        #expect(!labels.contains("https://app.agentrehub.com"), "服务器行只承诺主机名，不带协议")
        #expect(labels.contains("2"), "已授权设备条数")
        #expect(labels.contains(Self.text("me.language.zhHans")), "语言行显示当前取值")
        #expect(labels.contains(Self.text("me.appearance.dark")), "外观行显示当前取值")
        #expect(labels.contains("0.1.0 (1)"), "关于一行的版本号")
        #expect(labels.contains(Self.text("me.signOut")))
    }

    @Test("账号卡副行写邮箱，不写「通过 GitHub 授权」（决策 19）")
    func accountCardShowsEmailNotGithubClaim() async throws {
        let model = await loadedModel()
        let labels = await HostedScreen(view(model), size: Self.tall).labels()
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("github") }, "\(labels)")
    }

    @Test("语言偏好作用于界面：选了简体中文，同一个键读出中文；选了英文读出英文")
    func languageApplies() async throws {
        let zh = await HostedScreen(
            Text("me.signOut", tableName: "Me", bundle: AgentreUIResources.bundle)
                .displayPreferences(DisplayPreferences(language: .simplifiedChinese, appearance: .system))
        ).labels()
        #expect(zh.contains("退出登录"), "\(zh)")
        let en = await HostedScreen(
            Text("me.signOut", tableName: "Me", bundle: AgentreUIResources.bundle)
                .displayPreferences(DisplayPreferences(language: .english, appearance: .system))
        ).labels()
        #expect(en.contains("Sign Out"), "\(en)")
    }

    @Test("外观偏好映射到配色方案：跟随系统时不强加")
    func appearanceMaps() {
        #expect(DisplayAppearance.system.colorScheme == nil)
        #expect(DisplayAppearance.light.colorScheme == .light)
        #expect(DisplayAppearance.dark.colorScheme == .dark)
    }
}
