import AgentreDesign
import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import Foundation
import SwiftUI
import Testing
import UIKit

/// 系统字号放大到无障碍档时「已授权设备」二级页的设备行：设备名与平台完整可读，不被截断、不逐字折行。
/// 断言几何：截断的文字无障碍标签仍是全文，但排出来的框装不下它。
@MainActor
@Suite("「已授权设备」屏 · 无障碍字号")
struct MeLargeTextTests {
    /// iPhone 17 的逻辑宽度；高度放得下整页，List 才会把每一行都建出来。
    static let iPhone17 = CGSize(width: 402, height: 4000)

    /// 运行验证里被截断成「iPh…e 17」「wa…cal」、平台逐字折行的那一组设备。
    static let devices = [
        AuthorizedDevice(
            id: 7, name: "iPhone 17", displayName: "", kind: "mobile", platform: "ios", fingerprint: "phone-fingerprint-0001",
            lastSeenAt: 1_900_000_000_000, online: false, isThisDevice: true
        ),
        AuthorizedDevice(
            id: 8, name: "docker", displayName: "", kind: "agentred", platform: "linux", fingerprint: "docker-fingerprint-0008",
            lastSeenAt: 1_900_000_000_000, online: true, isThisDevice: false
        ),
        AuthorizedDevice(
            id: 9, name: "wanghu.local", displayName: "", kind: "agentred", platform: "darwin/arm64", fingerprint: "mac-fingerprint-0009",
            lastSeenAt: 1_899_000_000_000, online: false, isThisDevice: false
        ),
    ]

    func loadedModel() async -> MeModel {
        let account = FakeAccountService()
        await account.configure(devices: .success(Self.devices))
        let model = MeModel(
            account: account, servers: InMemoryServerAddressStore(), preferences: InMemoryDisplayPreferencesStore(),
            signOut: SignOut(session: AppSession(credentials: InMemoryCredentialStore(credentials: signedInCredentials)), store: EmptyStore())
        )
        await model.load()
        return model
    }

    /// 与视图同款的随包等宽字体（`.agentre(.body, mono: true)` / `.agentre(.caption, mono: true)`）在给定字号档下的 UIKit 对应。
    static func monospaced(_ role: FontRole, _ category: UIContentSizeCategory) -> UIFont {
        UIFont.agentre(role, mono: true, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }

    static func size(of text: String, font: UIFont, width: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
        ).size
    }

    @Test("accessibility-extra-large 下 iPhone 17 宽度：每台设备的名字完整显示、不被挤成窄条；平台单行完整、不逐字折行")
    func deviceRowsReadableAtAccessibilitySize() async throws {
        let model = await loadedModel()
        #expect(model.devices.count == Self.devices.count)
        let screen = HostedScreen(
            AuthorizedDevicesScreen(model: model).environment(\.dynamicTypeSize, .accessibility3),
            size: Self.iPhone17
        )
        let nameFont = Self.monospaced(.body, .accessibilityExtraLarge)
        let platformFont = Self.monospaced(.caption, .accessibilityExtraLarge)
        for device in Self.devices {
            let name = try #require(await screen.frame(of: device.shownName), "找不到设备名 \(device.shownName)")
            let full = Self.size(of: device.shownName, font: nameFont)
            // 名字的框装得下全文（允许按宽度换行，不允许截断）。
            let needed = Self.size(of: device.shownName, font: nameFont, width: name.width)
            #expect(needed.height <= name.height + 2, "\(device.shownName) 被截断：框 \(name)，全文需要 \(needed)")
            // 不被右侧的撤销出口挤成窄条：放得下一行的名字就占一整行宽。
            #expect(name.width + 2 >= min(full.width, Self.iPhone17.width * 0.6), "\(device.shownName) 被挤窄：框 \(name)，一行宽 \(full.width)")

            let platform = try #require(await screen.frame(of: device.platform), "找不到平台 \(device.platform)")
            let line = Self.size(of: device.platform, font: platformFont)
            #expect(platform.width + 2 >= line.width, "\(device.platform) 被截断或折行：框 \(platform)，一行宽 \(line.width)")
            #expect(platform.height <= line.height * 1.5, "\(device.platform) 逐字折行：框 \(platform)，一行高 \(line.height)")
        }
    }

    @Test("无障碍字号下撤销出口仍在：本机一枚撤销，其它设备写明到网页控制台撤销；在线与否仍写出来")
    func revokeExitsAtAccessibilitySize() async throws {
        let model = await loadedModel()
        let screen = HostedScreen(
            AuthorizedDevicesScreen(model: model).environment(\.dynamicTypeSize, .accessibility3),
            size: Self.iPhone17
        )
        let labels = await screen.labels()
        #expect(labels.filter { $0 == MeScreenTests.text("me.devices.revoke") }.count == 1, "\(labels)")
        #expect(labels.filter { $0 == MeScreenTests.text("me.devices.revokeInConsole") }.count == 2, "\(labels)")
        let texts = await screen.texts()
        #expect(texts.contains(MeScreenTests.text("me.devices.online")), "\(texts)")
        #expect(texts.contains(MeScreenTests.text("me.devices.offline")), "\(texts)")
    }

    @Test("无障碍字号下纵排后命中区仍补满 44×44、互不重叠；发现的目标数 = 放置的可点元素数")
    func hitTargetsAtAccessibilitySize() async throws {
        let model = await loadedModel()
        let report = await hitTargetReport(
            of: AuthorizedDevicesScreen(model: model).environment(\.dynamicTypeSize, .accessibility3),
            size: Self.iPhone17
        )
        #expect(report.targets.count == AuthorizedDevicesScreenTests.placedTargets(revocable: 1), "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }
}
