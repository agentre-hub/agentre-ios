import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import Foundation
import SwiftUI
import Testing

/// 「已授权设备」二级页（规格「09 我」：分组行「已授权设备（条数）」进这一页）：撤销只对本机生效，
/// 在线与否不只靠颜色，命中区补满 44×44 且互不重叠。
@MainActor
@Suite("「已授权设备」屏")
struct AuthorizedDevicesScreenTests {
    static let tall = CGSize(width: 390, height: 900)

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

    /// 放置的可点元素：本机一枚撤销（其它设备撤不了，那一行不放按钮）。
    static func placedTargets(revocable: Int) -> Int { revocable }

    @Test("每个可点元素的命中区补满 44×44 且互不重叠；发现的目标数 = 放置的可点元素数")
    func hitTargets() async throws {
        let model = await loadedModel()
        #expect(model.devices?.count == 2)
        let report = await hitTargetReport(of: AuthorizedDevicesScreen(model: model), size: Self.tall)
        #expect(report.targets.count == Self.placedTargets(revocable: 1), "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("屏上读得到：设备名（备注名优先）与本机标注")
    func facts() async throws {
        let model = await loadedModel()
        let labels = await HostedScreen(AuthorizedDevicesScreen(model: model), size: Self.tall).labels().joined(separator: "\n")
        #expect(labels.contains("iPhone"))
        #expect(labels.contains("工作室 Mac"))
        #expect(!labels.contains("studio.local"), "有备注名时不露主机名")
        #expect(labels.contains(Self.text("me.devices.thisDevice")))
    }

    @Test("撤销只对本机生效：本机那一行给撤销；其它设备照常列出，那一行写明到网页控制台撤销、不给撤不动的按钮")
    func revokeOnlyThisDevice() async throws {
        let model = await loadedModel()
        let labels = await HostedScreen(AuthorizedDevicesScreen(model: model), size: Self.tall).labels()
        #expect(labels.filter { $0 == Self.text("me.devices.revoke") }.count == 1, "\(labels)")
        #expect(labels.contains(Self.text("me.devices.revokeInConsole")), "\(labels)")
    }

    @Test("设备列表没取到：这一页如实说没取到并给重试，不是一张空列表")
    func devicesFailureIsSaid() async throws {
        let account = FakeAccountService()
        await account.configure(devices: .failure(URLError(.timedOut)))
        let model = await loadedModel(account: account)
        let labels = await HostedScreen(AuthorizedDevicesScreen(model: model), size: Self.tall).labels().joined(separator: "\n")
        #expect(labels.contains(Self.text("failure.timedOut")), "\(labels)")
        #expect(labels.contains(Self.text("me.retry")), "\(labels)")
    }

    @Test("设备在线与否不只靠颜色：每一行把在线 / 离线写出来")
    func deviceOnlineIsNotColourOnly() async throws {
        let model = await loadedModel()
        let texts = await HostedScreen(AuthorizedDevicesScreen(model: model), size: Self.tall).texts()
        #expect(texts.contains(Self.text("me.devices.online")), "\(texts)")
        #expect(texts.contains(Self.text("me.devices.offline")), "\(texts)")
    }
}
