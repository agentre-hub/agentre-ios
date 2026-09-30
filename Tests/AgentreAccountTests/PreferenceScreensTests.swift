import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import Foundation
import SwiftUI
import Testing

/// 「语言」「外观」二级页（规格「09 我」）：命中区，选中打勾，选了即生效。
@MainActor
@Suite("「语言」「外观」屏")
struct PreferenceScreensTests {
    func loadedModel() -> MeModel {
        MeModel(
            account: FakeAccountService(), servers: InMemoryServerAddressStore(), preferences: InMemoryDisplayPreferencesStore(),
            signOut: SignOut(session: AppSession(credentials: InMemoryCredentialStore(credentials: signedInCredentials)), store: EmptyStore())
        )
    }

    @Test("语言：命中区补满 44×44 且互不重叠，发现数 = 三个选项")
    func languageHitTargets() async throws {
        let model = loadedModel()
        let report = await hitTargetReport(of: LanguageScreen(model: model))
        #expect(report.targets.count == DisplayLanguage.allCases.count, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("外观：命中区补满 44×44 且互不重叠，发现数 = 三个选项")
    func appearanceHitTargets() async throws {
        let model = loadedModel()
        let report = await hitTargetReport(of: AppearanceScreen(model: model))
        #expect(report.targets.count == DisplayAppearance.allCases.count, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("选语言即生效：模型的偏好随之改写")
    func choosingLanguageUpdatesTheModel() throws {
        let model = loadedModel()
        model.setLanguage(.english)
        #expect(model.preferences.language == .english)
    }

    @Test("选外观即生效：模型的偏好随之改写")
    func choosingAppearanceUpdatesTheModel() throws {
        let model = loadedModel()
        model.setAppearance(.dark)
        #expect(model.preferences.appearance == .dark)
    }
}
