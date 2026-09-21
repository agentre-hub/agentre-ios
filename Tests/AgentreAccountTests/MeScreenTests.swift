import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import Foundation
import SwiftUI
import Testing

/// 「我」屏的视图层断言：逐屏命中区（发现数 = 放置数），以及屏上读得到的事实。
@MainActor
@Suite("「我」屏")
struct MeScreenTests {
    /// 整页一屏放得下：List 只建可见的行，屏太矮会让放置的按钮没被建出来。
    static let tall = CGSize(width: 390, height: 2000)

    static func text(_ key: String) -> String {
        AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Me")
    }

    func loadedModel(account: FakeAccountService = FakeAccountService()) async -> MeModel {
        let model = MeModel(
            account: account, servers: InMemoryServerAddressStore(), preferences: InMemoryDisplayPreferencesStore(),
            signOut: SignOut(session: AppSession(credentials: InMemoryCredentialStore(credentials: signedInCredentials)), store: EmptyStore())
        )
        await model.load()
        return model
    }

    /// 放置的可点元素：改服务器地址 1、每台设备的撤销 1、语言 3、外观 3、退出登录 1。
    static func placedTargets(devices: Int) -> Int {
        1 + devices + DisplayLanguage.allCases.count + DisplayAppearance.allCases.count + 1
    }

    @Test("每个可点元素的命中区补满 44×44 且互不重叠；发现的目标数 = 放置的可点元素数")
    func hitTargets() async throws {
        let model = await loadedModel()
        #expect(model.devices.count == 2)
        let report = await hitTargetReport(of: NavigationStack { MeView(model: model) }, size: Self.tall)
        #expect(Self.placedTargets(devices: 2) == 10)
        #expect(report.targets.count == Self.placedTargets(devices: 2), "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("载入失败时：失败事实与重试按钮也在命中区清单里")
    func hitTargetsWithFailure() async throws {
        let account = FakeAccountService()
        await account.configure(devices: .failure(URLError(.timedOut)))
        let model = await loadedModel(account: account)
        #expect(model.failure == .timedOut)
        let report = await hitTargetReport(of: NavigationStack { MeView(model: model) }, size: Self.tall)
        #expect(report.targets.count == Self.placedTargets(devices: 0) + 1, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
        let labels = await HostedScreen(NavigationStack { MeView(model: model) }, size: Self.tall).labels().joined(separator: "\n")
        #expect(labels.contains(Self.text("failure.timedOut")), "\(labels)")
    }

    @Test("屏上读得到：账号、服务器地址、设备名（备注名优先）与本机标注、语言与外观的选项、退出登录")
    func facts() async throws {
        let model = await loadedModel()
        let labels = await HostedScreen(NavigationStack { MeView(model: model) }, size: Self.tall).labels().joined(separator: "\n")
        #expect(labels.contains("Ada"))
        #expect(labels.contains("ada@example.com"))
        #expect(labels.contains("https://app.agentrehub.com"))
        #expect(labels.contains("iPhone"))
        #expect(labels.contains("工作室 Mac"))
        #expect(!labels.contains("studio.local"), "有备注名时不露主机名")
        #expect(labels.contains(Self.text("me.devices.thisDevice")))
        #expect(labels.contains(Self.text("me.language.zhHans")))
        #expect(labels.contains(Self.text("me.appearance.dark")))
        #expect(labels.contains(Self.text("me.signOut")))
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
