import AgentreDomain
import AgentreTestSupport
import Foundation
@testable import AgentreUI
import SwiftUI
import Testing

/// 机器标签与机器详情的视图层断言：逐屏命中区（发现数 = 放置数），以及屏上呈现的事实。
@MainActor
@Suite("机器屏")
struct MachineScreensTests {
    static func text(_ key: String) -> String {
        AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Machines")
    }

    func roster() async -> MachinesView {
        struct Roster: MachineRoster {
            func machines() -> [Machine] {
                [
                    Machine(id: 1, fingerprint: "fp-1", name: "studio-mac", online: true),
                    Machine(id: 2, fingerprint: "fp-2", name: "build-box", online: false, lastSeenAt: 1_800_000_000_000),
                    Machine(id: 3, fingerprint: "fp-3", name: "laptop", online: true),
                ]
            }
        }
        let model = MachinesModel(roster: Roster())
        await model.load()
        #expect(model.machines.count == 3)
        return MachinesView(model: model, onOpen: { _ in })
    }

    func detail(machine: Machine = onlineMachine()) async -> MachineDetailModel {
        let source = FakeSessionSource([
            session("c-saved-1", title: "Fix build", lifecycle: "running"),
            session("c-new-1", title: "Write docs", waiting: true),
            session("c-saved-2", title: "Refactor relay"),
            session("c-new-2", title: ""),
        ])
        await source.setCounts(MachineSessionCounts(total: 17, running: 3, waiting: 2))
        let store = FakeSavingStore(saved: [key("c-saved-1"), key("c-saved-2")])
        let model = MachineDetailModel(machine: machine, sessions: source, store: store, transfer: FakeTransfer(), pageSize: 10)
        await model.load()
        return model
    }

    static func failureText(_ key: String) -> String {
        AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Me")
    }

    actor ScriptedRoster: MachineRoster {
        let result: Result<[Machine], any Error>
        init(_ result: Result<[Machine], any Error>) { self.result = result }
        func machines() throws -> [Machine] { try result.get() }
    }

    func rosterScreen(_ result: Result<[Machine], any Error>) async -> MachinesView {
        let model = MachinesModel(roster: ScriptedRoster(result))
        await model.load()
        return MachinesView(model: model, onOpen: { _ in })
    }

    @Test("名册没取到：如实说出事实并给重试，不是一片空白")
    func rosterFailureIsStated() async throws {
        let view = await rosterScreen(.failure(URLError(.notConnectedToInternet)))
        let labels = await HostedScreen(view).labels()
        #expect(labels.contains(Self.failureText("failure.offline")), "\(labels)")
        #expect(labels.contains(Self.failureText("me.retry")), "\(labels)")
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 1, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("账号下没有在线机器：呈现「没有可用的机器」及其原因；机器照常列出")
    func noOnlineMachineIsStated() async throws {
        let offline = await HostedScreen(await rosterScreen(.success([
            Machine(id: 2, fingerprint: "fp-2", name: "build-box", online: false, lastSeenAt: 1_800_000_000_000),
        ]))).labels()
        #expect(offline.contains(Self.failureText("failure.noMachine.offline")), "\(offline)")
        #expect(offline.contains { $0.contains("build-box") }, "\(offline)")
        let none = await HostedScreen(await rosterScreen(.success([]))).labels()
        #expect(none.contains(Self.failureText("failure.noMachine.unpaired")), "\(none)")
        let some = await HostedScreen(await roster()).labels()
        #expect(!some.contains { $0.hasPrefix(Self.failureText("failure.noMachine.unspecified")) }, "有机器在线时不说没有可用的机器：\(some)")
    }

    @Test("完全离线：机器详情如实说这台设备没有联网，而不是说没连上那台机器；保存到手机点不动")
    func detailWhenDeviceOffline() async throws {
        let model = await detail()
        let screen = HostedScreen(NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) }.environment(\.isOffline, true))
        let labels = await screen.labels()
        #expect(labels.contains(Self.text("machines.detail.deviceOffline")), "\(labels)")
        #expect(!labels.contains(Self.text("machines.detail.unreachable")), "\(labels)")
        #expect(await screen.disabledLabels().contains(Self.text("machines.detail.save")))
    }

    @Test("App 内选的语言与系统不同、再切回：按标题搜索框的占位与读屏标签随之换成那种语言")
    func searchFieldFollowsInAppLanguage() async throws {
        let model = await detail()
        let mismatches = await inAppLanguageMismatches(
            of: NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) }, bundle: AgentreUIResources.bundle,
            copy: [("machines.detail.search", "Machines")]
        )
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test("名册：每台机器一个按钮，命中区补满 44×44 且互不重叠；发现数 = 3")
    func rosterHitTargets() async throws {
        let report = await hitTargetReport(of: await roster())
        #expect(report.targets.count == 3, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("名册：机器名与在线态在行上")
    func rosterRows() async throws {
        let labels = await HostedScreen(await roster()).labels().joined(separator: "\n")
        #expect(labels.contains("studio-mac"))
        #expect(labels.contains("build-box"))
        #expect(labels.contains(Self.text("machines.offline")))
        #expect(labels.contains(Self.text("machines.online")))
    }

    @Test("详情：搜索框、已保存的两行各一个进入按钮、未保存的两行各一个「保存到手机」；发现数 = 5")
    func detailHitTargets() async throws {
        let model = await detail()
        #expect(model.rows.count == 4)
        let view = NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) }
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 5, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("详情：三个计数在顶上；未保存的行给出「保存到手机」，已保存的行标明在手机上；搜索只承诺标题")
    func detailFacts() async throws {
        let model = await detail()
        let labels = await HostedScreen(NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) }).labels()
        let joined = labels.joined(separator: "\n")
        #expect(Array(labels.prefix(6)) == [
            "17", "3", "2",
            Self.text("machines.detail.count.total"), Self.text("machines.detail.count.running"), Self.text("machines.detail.count.waiting"),
        ], "\(labels)")
        #expect(labels.filter { $0 == Self.text("machines.detail.save") }.count == 2, "\(labels)")
        let savedRows = labels.filter { $0.contains(Self.text("machines.detail.saved")) }
        #expect(savedRows.count == 2, "\(labels)")
        #expect(savedRows.allSatisfy { $0.contains("Fix build") || $0.contains("Refactor relay") })
        #expect(joined.contains("Write docs"))
        #expect(joined.contains("c-new-2"))
        // 提示文案说出「只按标题」：两种语言都点明标题，不写 Agent、项目、机器。
        for (language, word) in [("en", "title"), ("zh-Hans", "标题")] {
            let path = try #require(AgentreUIResources.bundle.path(forResource: language, ofType: "lproj"))
            let prompt = try #require(Bundle(path: path)).localizedString(forKey: "machines.detail.search", value: nil, table: "Machines")
            #expect(prompt.localizedCaseInsensitiveContains(word), "\(language): \(prompt)")
        }
        #expect(labels.contains(Self.text("machines.detail.search")))
    }

    @Test("详情：会话的状态不只靠颜色——运行中与等你处理的行各带一枚写明状态的图标，闲着的行不带")
    func detailStatusIsNotColourOnly() async throws {
        let model = await detail()
        let labels = await HostedScreen(NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) }).labels()
        let status = { (key: String) in AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Messages") }
        // 已保存的行是一枚按钮，标签连成一句。
        let running = try #require(labels.first { $0.contains("Fix build") }, "\(labels)")
        #expect(running.contains(status("messages.status.running")), "\(running)")
        let idle = try #require(labels.first { $0.contains("Refactor relay") }, "\(labels)")
        #expect(!idle.contains(status("messages.status.running")) && !idle.contains(status("messages.status.waiting")), "\(idle)")
        // 未保存的行不是按钮，状态图标自成一个元素；顶上计数的「等你处理」是另一个。
        #expect(labels.filter { $0 == status("messages.status.waiting") }.count == 2, "\(labels)")
    }

    @Test("详情离线：呈现「不在线」，没有计数也没有会话")
    func detailOffline() async throws {
        let model = await detail(machine: offlineMachine())
        let labels = await HostedScreen(NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) }).labels()
        let joined = labels.joined(separator: "\n")
        #expect(joined.contains(Self.text("machines.offline")))
        #expect(!joined.contains("17"))
        #expect(!joined.contains(Self.text("machines.detail.count.total")))
        #expect(!joined.contains("Fix build"))
        #expect(!labels.contains(Self.text("machines.detail.save")))
    }
}
