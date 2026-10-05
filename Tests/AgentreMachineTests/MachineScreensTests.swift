import AgentreDesign
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
                    Machine(id: 1, fingerprint: "fp-1", name: "studio-mac", kind: "desktop", platform: "darwin/arm64", version: "0.9.2", online: true),
                    Machine(
                        id: 2, fingerprint: "fp-2", name: "build-box", kind: "agentred", platform: "linux", version: "0.8.7",
                        online: false, lastSeenAt: 1_800_000_000_000
                    ),
                    Machine(id: 3, fingerprint: "fp-3", name: "laptop", kind: "agentred", platform: "darwin", version: "0.9.2", online: true),
                ]
            }
        }
        let sessions = FakeSessionSource([])
        await sessions.setCounts(MachineSessionCounts(total: 12, running: 2, waiting: 1), for: "fp-1")
        // laptop（fp-3）在线但没有任何会话：为零的项不写，整块计数都不出现。
        await sessions.setCounts(MachineSessionCounts(total: 0, running: 0, waiting: 0), for: "fp-3")
        let model = MachinesModel(roster: Roster(), sessions: sessions)
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
        let model = MachinesModel(roster: ScriptedRoster(result), sessions: FakeSessionSource([]))
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

    @Test("名册：机器名在行上；副标题写已配对与在线的台数")
    func rosterRows() async throws {
        let labels = await HostedScreen(await roster()).labels()
        let joined = labels.joined(separator: "\n")
        #expect(joined.contains("studio-mac"))
        #expect(joined.contains("build-box"))
        // 3 台已配对（studio-mac、build-box、laptop），2 台在线（studio-mac、laptop）。
        #expect(labels.contains(String(format: Self.text("machines.subtitle %lld %lld"), 3, 2)), "\(labels)")
    }

    @Test("名册：等宽「平台 · 种类 版本」按上报原样；在线机器现算的会话计数，为零的项不写；离线机器没有会话数、只写最后在线")
    func rosterCards() async throws {
        let labels = await HostedScreen(await roster()).labels()
        let joined = labels.joined(separator: "\n")
        #expect(joined.contains("darwin/arm64 · desktop 0.9.2"), "\(labels)")
        #expect(joined.contains("linux · agentred 0.8.7"), "\(labels)")
        let studio = try #require(labels.first { $0.contains("studio-mac") }, "\(labels)")
        #expect(studio.contains(String(format: Self.text("machines.count.sessions %lld"), 12)), "\(studio)")
        #expect(studio.contains(String(format: Self.text("machines.count.running %lld"), 2)), "\(studio)")
        #expect(studio.contains(String(format: Self.text("machines.count.waiting %lld"), 1)), "\(studio)")
        // laptop（在线，0 个会话）：为零的项不写，整块计数都不出现。
        let laptop = try #require(labels.first { $0.contains("laptop") }, "\(labels)")
        #expect(!laptop.localizedCaseInsensitiveContains("session") && !laptop.contains("个会话"), "\(laptop)")
        // build-box（离线）：没有会话数，只写最后在线时刻（决策 19：离线机器的会话数没有来源）。
        let buildBox = try #require(labels.first { $0.contains("build-box") }, "\(labels)")
        #expect(!buildBox.localizedCaseInsensitiveContains("session") && !buildBox.contains("个会话"), "\(buildBox)")
        let lastSeenPrefix = Self.text("machines.lastSeen %@").replacingOccurrences(of: "%@", with: "").trimmingCharacters(in: .whitespaces)
        #expect(buildBox.contains(lastSeenPrefix), "\(buildBox)")
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

    @Test("详情：会话的状态不只靠颜色——每行的状态点读出状态名，闲着的行不读成运行中或等你处理")
    func detailStatusIsNotColourOnly() async throws {
        let model = await detail()
        let labels = await HostedScreen(NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) }).labels()
        let status = { (key: String) in AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Messages") }
        // 已保存的行是一枚按钮，标签连成一句。
        let running = try #require(labels.first { $0.contains("Fix build") }, "\(labels)")
        #expect(running.contains(status("messages.status.running")), "\(running)")
        let idle = try #require(labels.first { $0.contains("Refactor relay") }, "\(labels)")
        #expect(!idle.contains(status("messages.status.running")) && !idle.contains(status("messages.status.waiting")), "\(idle)")
        // 未保存的行不是按钮，状态点自成一个元素；顶上计数的「等你处理」是另一个。
        #expect(labels.filter { $0 == status("messages.status.waiting") }.count == 2, "\(labels)")
    }

    @Test("详情：闲着（含中断）的行也有状态点，不留一块空白；点在行首、标题之前")
    func idleRowsHaveStatusDot() async throws {
        let source = FakeSessionSource([
            session("c-interrupted", title: "Interrupted run", lifecycle: "interrupted"),
            session("c-idle", title: "Idle chat"),
        ])
        let model = MachineDetailModel(machine: onlineMachine(), sessions: source, store: FakeSavingStore(), transfer: FakeTransfer(), pageSize: 10)
        await model.load()
        let screen = HostedScreen(NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) })
        let idle = Self.text("machines.detail.status.idle")
        let labels = await screen.labels()
        // 未保存的行不是按钮：每行的状态点自成一个元素。
        #expect(labels.filter { $0 == idle }.count == 2, "\(labels)")
        let dot = try #require(await screen.frame(of: idle), "闲着的行没有状态点")
        let title = try #require(await screen.frame(of: "Interrupted run"))
        #expect(dot.width > 0 && dot.height > 0, "\(dot)")
        #expect(dot.maxX <= title.minX, "状态点 \(dot) 应在标题 \(title) 之前")
        // 点的颜色：运行中 run、等你处理 amber、失败 coral（「红表失败」），闲着 idle（稿子的灰点）。
        let activities: [ConversationActivity] = [.typing, .waiting, .failed, .idle]
        #expect(activities.map(MachineSessionStatusDot.token(for:)) == [ColorToken.run, .amber, .coral, .idle])
    }

    @Test("详情：状态不只靠颜色——闲着的行是稿子的灰点，运行中、等你处理、失败各是一枚形状不同的图标")
    func detailStatusMarksDifferByShape() {
        let activities: [ConversationActivity] = [.typing, .waiting, .failed, .idle]
        let marks = activities.map(MachineSessionStatusDot.mark(for:))
        #expect(marks.last == .dot, "\(marks)")
        let symbols = marks.dropLast().compactMap { mark -> String? in
            if case .symbol(let name) = mark { name } else { nil }
        }
        #expect(symbols.count == 3 && Set(symbols).count == 3, "\(marks)")
    }

    @Test("详情离线：呈现「这台机器不在线」，没有计数也没有会话")
    func detailOffline() async throws {
        let model = await detail(machine: offlineMachine())
        let labels = await HostedScreen(NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) }).labels()
        let joined = labels.joined(separator: "\n")
        #expect(joined.contains(Self.text("machines.detail.offline")), "\(labels)")
        #expect(!joined.contains("17"))
        #expect(!joined.contains(Self.text("machines.detail.count.total")))
        #expect(!joined.contains("Fix build"))
        #expect(!labels.contains(Self.text("machines.detail.save")))
    }

    @Test("详情：每行的等宽工作目录与标题、相对时间同在，没有路径的行不留空白")
    func detailRowsShowCwd() async throws {
        let source = FakeSessionSource([session("c1", title: "Fix build", cwd: "~/Code/agentre/agentre-ios"), session("c2", title: "No path")])
        let model = MachineDetailModel(machine: onlineMachine(), sessions: source, store: FakeSavingStore(), transfer: FakeTransfer(), pageSize: 10)
        await model.load()
        let labels = await HostedScreen(NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) }).labels()
        let joined = labels.joined(separator: "\n")
        #expect(joined.contains("~/Code/agentre/agentre-ios"), "\(labels)")
    }

    @Test("详情：「再加载 N 条」取代自动翻页，N = 总数减已列出、以一页为上限；点它接着翻页；没有更多时不出现")
    func reloadMoreButtonReplacesAutomaticPaging() async throws {
        let source = FakeSessionSource((0..<5).map { session("c\($0)", title: "task \($0)", at: Int64(10_000 - $0)) })
        let model = MachineDetailModel(machine: onlineMachine(), sessions: source, store: FakeSavingStore(), transfer: FakeTransfer(), pageSize: 2)
        await model.load()
        let screen = HostedScreen(NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) })
        let reloadLabel = String(format: Self.text("machines.detail.reloadMore %lld"), 2)
        let firstPageLabels = await screen.labels()
        #expect(firstPageLabels.contains(reloadLabel), "\(firstPageLabels)")
        // 只是滚到底不该自动翻页：没有点按钮之前，清单不变。
        #expect(model.rows.count == 2)
        let button = try #require(await screen.frame(of: reloadLabel), "找不到「再加载」按钮")
        #expect(button.height >= 44, "\(button)")
        await model.loadMore()
        #expect(model.rows.count == 4)
        await model.loadMore()
        #expect(model.rows.count == 5)
        #expect(model.reloadCount == nil, "列全了，没有更多")
        let finalScreen = HostedScreen(NavigationStack { MachineDetailView(model: model, onOpen: { _ in }) })
        let fragment = Self.text("machines.detail.reloadMore %lld").replacingOccurrences(of: "%lld", with: "").trimmingCharacters(in: .whitespaces)
        let finalLabels = await finalScreen.labels()
        #expect(!finalLabels.joined(separator: "\n").contains(fragment), "\(finalLabels)")
    }

    @Test("会话行的标题从行首起排、占去行宽的大半：闲着的行与等你处理 / 运行中 / 失败的行都一样（iPhone 17 宽度）")
    func sessionTitleStartsAtRowLeadingAndFillsTheRow() async throws {
        let long = "只用文字回答，绝对不要调用任何工具、不要读写任何文件：写一段大约 800 字的短文，介绍 Go 语言的并发模型。"
        let sessions = [
            session("c-idle", title: "闲着 · " + long, at: 400),
            session("c-waiting", title: "等你 · " + long, lifecycle: "running", waiting: true, at: 300),
            session("c-running", title: "运行 · " + long, lifecycle: "running", at: 200),
            session("c-failed", title: "失败 · " + long, lifecycle: "failed", at: 100),
        ]
        let model = MachineDetailModel(
            machine: onlineMachine(), sessions: FakeSessionSource(sessions), store: FakeSavingStore(), transfer: FakeTransfer(), pageSize: 10
        )
        await model.load()
        #expect(model.rows.count == 4)
        let phoneWidth: CGFloat = 402, rowInset: CGFloat = 16
        let screen = HostedScreen(MachineDetailView(model: model, onOpen: { _ in }), size: CGSize(width: phoneWidth, height: 874))
        let rowWidth = phoneWidth - 2 * rowInset
        for session in sessions {
            let title = try #require(await screen.frame(of: session.title), "找不到标题 \(session.title)")
            // 行内留白加一枚状态图标的位置：标题不得再往右。
            #expect(title.minX - rowInset <= 44, "\(session.conversationID)：标题起于 \(title.minX)")
            // 相对时间与保存入口排在同一行的行尾（稿子 06）：标题占去其余的大半，与消息列表同一判据。
            #expect(title.width >= rowWidth * 0.5, "\(session.conversationID)：标题宽 \(title.width) / 行宽 \(rowWidth)")
        }
    }
}
