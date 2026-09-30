import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import Foundation
import SwiftUI
import Testing

/// 「服务器」二级页（规格「09 我」）：地址编辑。切到另一台服务器退出登录的行为本身由
/// `MeModelTests.editServer` 核实；这里只断言这一屏自己的命中区。
@MainActor
@Suite("「服务器」屏")
struct ServerAddressScreenTests {
    func loadedModel(server: ServerAddress = .production) -> MeModel {
        MeModel(
            account: FakeAccountService(), servers: InMemoryServerAddressStore(server), preferences: InMemoryDisplayPreferencesStore(),
            signOut: SignOut(session: AppSession(credentials: InMemoryCredentialStore(credentials: signedInCredentials)), store: EmptyStore())
        )
    }

    @Test("命中区补满 44×44 且互不重叠：地址输入框 + 取消 + 保存")
    func hitTargets() async throws {
        let model = loadedModel()
        let report = await hitTargetReport(of: ServerAddressScreen(model: model))
        #expect(report.targets.count >= 3, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }
}
