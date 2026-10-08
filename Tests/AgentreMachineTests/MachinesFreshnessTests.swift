import AgentreDomain
import AgentreTestSupport
import Foundation
@testable import AgentreUI
import SwiftUI
import Testing
import UIKit

/// 机器页如实反映在线状态（report-17 08c）：App 开着时机器上线了，下拉刷新与 App 回到前台
/// 都要让名册按服务端此刻的在线态重排、副标题重算——不能停在冷启动那一次的名册上。
@MainActor
@Suite("机器标签：名册随刷新跟上服务端")
struct MachinesFreshnessTests {
    /// 两次载入之间会变的名册：服务端那一侧机器上线 / 下线。
    actor ChangingRoster: MachineRoster {
        private var current: [Machine]
        private(set) var fetches = 0
        init(_ machines: [Machine]) { current = machines }
        func set(_ machines: [Machine]) { current = machines }
        func machines() -> [Machine] {
            fetches += 1
            return current
        }
    }

    /// 测试里切换的场景阶段：真机上由系统给出，这里经环境注入。
    @Observable
    final class Phase {
        var value: ScenePhase = .active
    }

    struct PhaseHost: View {
        let phase: Phase
        let content: MachinesView
        var body: some View { content.environment(\.scenePhase, phase.value) }
    }

    /// 托管进窗口的一屏；与 `HostedScreen` 不同，这里要摸到 UIKit 那层的下拉刷新控件。
    @MainActor
    final class Window {
        let window: UIWindow
        let controller: UIViewController

        init(_ view: some View) {
            controller = UIHostingController(rootView: view)
            window = MachinesFreshnessTests.sceneWindow()
            window.rootViewController = controller
            window.makeKeyAndVisible()
        }

        isolated deinit { window.isHidden = true }

        /// 屏上 UIKit 文本框此刻的文字。
        func textFieldTexts() -> [String] {
            controller.view.layoutIfNeeded()
            func find(_ view: UIView) -> [String] {
                ((view as? UITextField).map { [$0.text ?? ""] } ?? []) + view.subviews.flatMap(find)
            }
            return find(controller.view)
        }

        /// 列表的下拉刷新控件；没挂 `.refreshable` 时为 nil。
        func refreshControl() async -> UIRefreshControl? {
            for _ in 0..<5 {
                controller.view.layoutIfNeeded()
                try? await Task.sleep(for: .milliseconds(50))
            }
            func find(_ view: UIView) -> UIRefreshControl? {
                if let scroll = view as? UIScrollView, let control = scroll.refreshControl { return control }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(controller.view)
        }
    }

    /// 托管窗口挂在宿主 App 的场景上（没有场景的窗口里，列表的刷新动作照样挂着，但测试里摸不到真实手势）。
    static func sceneWindow() -> UIWindow {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return UIWindow(frame: frame) }
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        return window
    }

    static let wentOffline = Machine(id: 7, fingerprint: "fp-box", name: "build-box", kind: "agentred", online: false, lastSeenAt: 1_800_000_000_000)
    static let cameOnline = Machine(id: 7, fingerprint: "fp-box", name: "build-box", kind: "agentred", online: true, lastSeenAt: 1_900_000_000_000)

    static func subtitle(paired: Int, online: Int) -> String {
        String(format: MachineScreensTests.text("machines.subtitle %lld %lld"), paired, online)
    }

    @Test("下拉刷新：机器在 App 开着时上线了，刷新后名册与副标题按服务端此刻的在线态显示")
    func pullToRefreshPicksUpPresence() async throws {
        let roster = ChangingRoster([Self.wentOffline])
        let model = MachinesModel(roster: roster, sessions: FakeSessionSource([]))
        let host = Window(MachinesView(model: model, onOpen: { _ in }))
        try await eventually("cold load") { model.unavailable == .offline }

        await roster.set([Self.cameOnline])
        let control = try #require(await host.refreshControl(), "机器页没有下拉刷新")
        control.pull()

        try await eventually("roster refreshed by pull-down") { model.machines.first?.online == true }
        #expect(model.unavailable == nil)
        let labels = await HostedScreen(MachinesView(model: model, onOpen: { _ in })).labels()
        #expect(labels.contains(Self.subtitle(paired: 1, online: 1)), "\(labels)")
        _ = host
    }

    /// 外壳选中的 tab：真机上由浮动 tab 栏改写，这里由测试改写。
    @Observable
    final class Selection {
        var tab: ShellTab = .machines
    }

    struct ShellHost: View {
        @Bindable var selection: Selection
        let machines: MachinesView
        var body: some View {
            ShellView(selection: $selection.tab, showsTabBar: true) {
                Text(verbatim: "messages")
            } machines: {
                machines
            } me: {
                Text(verbatim: "me")
            }
        }
    }

    @Test("回到机器 tab：切去别的 tab 期间机器上线了，再选中机器 tab 即重取名册（页一直挂着，进屏载入不会再跑）")
    func reselectingTabPicksUpPresence() async throws {
        let roster = ChangingRoster([Self.wentOffline])
        let model = MachinesModel(roster: roster, sessions: FakeSessionSource([]))
        let selection = Selection()
        let host = Window(ShellHost(selection: selection, machines: MachinesView(model: model, onOpen: { _ in })))
        try await eventually("cold load") { model.unavailable == .offline }

        selection.tab = .messages
        try await Task.sleep(for: .milliseconds(100))
        await roster.set([Self.cameOnline])
        #expect(await roster.fetches == 1, "离开机器 tab 不该重取")
        selection.tab = .machines

        try await eventually("roster refreshed on re-selecting the Machines tab") { model.machines.first?.online == true }
        #expect(model.unavailable == nil)
        _ = host
    }

    @Test("回到前台：机器在 App 退到后台期间上线了，回到前台即重取名册")
    func foregroundPicksUpPresence() async throws {
        let roster = ChangingRoster([Self.wentOffline])
        let model = MachinesModel(roster: roster, sessions: FakeSessionSource([]))
        let phase = Phase()
        let host = Window(PhaseHost(phase: phase, content: MachinesView(model: model, onOpen: { _ in })))
        try await eventually("cold load") { model.unavailable == .offline }

        phase.value = .background
        try await Task.sleep(for: .milliseconds(100))
        await roster.set([Self.cameOnline])
        phase.value = .active

        try await eventually("roster refreshed on returning to the foreground") { model.machines.first?.online == true }
        #expect(model.unavailable == nil)
        _ = host
    }

    struct PhasedShellHost: View {
        let phase: Phase
        let selection: Selection
        let machines: MachinesView
        var body: some View {
            ShellHost(selection: selection, machines: machines).environment(\.scenePhase, phase.value)
        }
    }

    @Test("回到前台时停在别的 tab：机器页不重取（不白把每台在线机器的计数问一遍），等选中机器 tab 时再取")
    func foregroundOnAnotherTabWaitsForSelection() async throws {
        let roster = ChangingRoster([Self.wentOffline])
        let model = MachinesModel(roster: roster, sessions: FakeSessionSource([]))
        let selection = Selection()
        let phase = Phase()
        let host = Window(PhasedShellHost(phase: phase, selection: selection, machines: MachinesView(model: model, onOpen: { _ in })))
        try await eventually("cold load") { model.unavailable == .offline }

        selection.tab = .messages
        try await Task.sleep(for: .milliseconds(100))
        phase.value = .background
        try await Task.sleep(for: .milliseconds(100))
        await roster.set([Self.cameOnline])
        phase.value = .active
        try await Task.sleep(for: .milliseconds(300))
        #expect(await roster.fetches == 1, "机器 tab 不在前面，回到前台不该重取")

        selection.tab = .machines
        try await eventually("roster refreshed on selecting the Machines tab") { model.machines.first?.online == true }
        #expect(await roster.fetches == 2)
        _ = host
    }

    /// 机器详情的宿主：真机上名册重取后这台机器的在线态变了，装配层就换一个详情模型给同一处的详情屏。
    @Observable
    final class DetailHolder {
        var model: MachineDetailModel
        init(_ model: MachineDetailModel) { self.model = model }
    }

    struct DetailHost: View {
        let holder: DetailHolder
        var body: some View {
            NavigationStack { MachineDetailView(model: holder.model, onOpen: { _ in }) }
        }
    }

    @Test("详情开着时名册重取、这台机器上线了：换进来的新详情模型照样问机器要会话与计数，而不是一片空白")
    func swappedDetailModelLoads() async throws {
        let source = FakeSessionSource([session("c-1", title: "Fix build")])
        await source.setCounts(MachineSessionCounts(total: 1, running: 0, waiting: 0))
        let offline = MachineDetailModel(machine: offlineMachine(), sessions: source, store: FakeSavingStore(), transfer: FakeTransfer())
        let holder = DetailHolder(offline)
        let host = Window(DetailHost(holder: holder))
        try await Task.sleep(for: .milliseconds(200))

        let online = MachineDetailModel(machine: onlineMachine(), sessions: source, store: FakeSavingStore(), transfer: FakeTransfer())
        holder.model = online
        try await eventually("the swapped-in detail model loads") { online.rows.map(\.key.conversationID) == ["c-1"] && online.counts != nil }
        _ = host
    }

    @Test("详情的搜索框写的是它所驱动的那个模型的搜索词（同一台机器再进来，清单仍按上次的词收窄）")
    func detailSearchFieldMirrorsModelKeyword() async throws {
        let source = FakeSessionSource([session("c-1", title: "Fix build"), session("c-2", title: "Write docs")])
        let model = MachineDetailModel(machine: onlineMachine(), sessions: source, store: FakeSavingStore(), transfer: FakeTransfer())
        await model.search("fix")
        let host = Window(DetailHost(holder: DetailHolder(model)))
        try await eventually("search field shows the model's keyword") { host.textFieldTexts() == ["fix"] }
        #expect(model.rows.map(\.key.conversationID) == ["c-1"])
    }

    @Test("全部离线：副标题照样写「N 台已配对 · 0 台在线」，与「没有可用的机器」并存")
    func allOfflineStillStatesCounts() async throws {
        let roster = ChangingRoster([
            Self.wentOffline,
            Machine(id: 8, fingerprint: "fp-mac", name: "studio-mac", kind: "desktop", online: false, lastSeenAt: 1_800_000_000_000),
        ])
        let model = MachinesModel(roster: roster, sessions: FakeSessionSource([]))
        await model.load()
        let labels = await HostedScreen(MachinesView(model: model, onOpen: { _ in })).labels()
        #expect(labels.contains(Self.subtitle(paired: 2, online: 0)), "\(labels)")
        #expect(labels.contains(MachineScreensTests.failureText("failure.noMachine.offline")), "\(labels)")
    }
}

private extension UIRefreshControl {
    /// 松手那一刻控件触发的动作：对 valueChanged 上登记的每个目标直接调它登记的方法。
    /// 实测经 `sendActions(for:)` / `sendAction(_:to:for:)` 转发时列表的刷新动作不会跑，直接调才会。
    func pull() {
        for target in allTargets {
            for action in actions(forTarget: target, forControlEvent: .valueChanged) ?? [] {
                _ = (target.base as? NSObject)?.perform(NSSelectorFromString(action), with: self)
            }
        }
    }
}
