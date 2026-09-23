import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import SwiftUI
import Testing

/// 输入区与更多面板的视图层断言：屏上呈现的事实，与命中区（发现的目标数 = 放的可点元素数）。
@MainActor
@Suite("输入区视图")
struct ComposerScreenTests {
    let usage = ContextUsage(used: 40_000, max: 100_000)

    @Test("常驻行：面板入口、三枚图标（不带文字）、右端上下文环；连同输入框与发送共 7 块命中区，补满且互不重叠")
    func permanentRow() async throws {
        let model = composer()
        await model.load()
        let view = ComposerView(model: model, contextUsage: usage, onDeleted: {})
        let labels = await HostedScreen(view).labels()
        for label in ["composer.more", "composer.permissionMode", "composer.model", "composer.effort"] {
            #expect(labels.contains(text(label)), "\(label) in \(labels)")
        }
        // 三项的当前取值不在常驻行上：那是面板的事。
        #expect(!labels.contains { $0.contains("acceptEdits") || $0.contains("claude-sonnet") })
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 7, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
        // 上下文环在最右端。
        let ring = try #require(report.targets.max { $0.maxX < $1.maxX })
        #expect(report.targets.filter { abs($0.midY - ring.midY) < 1 }.count == 5)
    }

    @Test("上下文窗口不为正：环整块不渲染")
    func noRing() async throws {
        let model = composer()
        let report = await hitTargetReport(of: ComposerView(model: model, contextUsage: nil, onDeleted: {}))
        #expect(report.targets.count == 6, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("一轮运行中：输入框仍在，排着的几条逐条列出并如实说何时发出；可撤的每条一枚撤回")
    func queued() async throws {
        let relay = FakeComposerRelay()
        await relay.set(steerHandle: { ComposerSteerHandle(queuedID: "exec-\($0)", cancellable: $0 == "local-1") })
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "先别动数据库"
        await model.send()
        model.text = "再跑一次测试"
        await model.send()
        let view = ComposerView(model: model, contextUsage: usage, onDeleted: {})
        let labels = await HostedScreen(view).labels()
        #expect(labels.contains(text("composer.queued %lld", 2)), "\(labels)")
        #expect(labels.contains("先别动数据库") && labels.contains("再跑一次测试"))
        #expect(labels.contains(text("composer.cancelQueued")))
        let report = await hitTargetReport(of: view)
        // 常驻 7 块 + 停止本轮 + 可撤的那一条的撤回。
        #expect(report.targets.count == 9, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("停止本轮只在一轮真的在跑时摆出来，与排队并存；点下去发出停止")
    func stopButton() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        let idle = await HostedScreen(ComposerView(model: model, contextUsage: usage, onDeleted: {})).labels()
        #expect(!idle.contains(text("composer.stop")), "\(idle)")
        model.turnStarted()
        let view = ComposerView(model: model, contextUsage: usage, onDeleted: {})
        let running = await HostedScreen(view).labels()
        #expect(running.contains(text("composer.stop")), "\(running)")
        #expect(running.contains(text("composer.send")), "运行中输入框与发送照常在")
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 8, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("完全离线：输入框照常可打字，发送与停止不可用，如实说这台设备没有联网")
    func offline() async throws {
        let model = composer()
        model.turnStarted()
        model.text = "还在吗"
        let online = HostedScreen(ComposerView(model: model, contextUsage: usage, onDeleted: {}))
        #expect(await !online.disabledLabels().contains(text("composer.send")))
        #expect(await !online.labels().contains(text("composer.deviceOffline")))
        let screen = HostedScreen(ComposerView(model: model, contextUsage: usage, onDeleted: {}).environment(\.isOffline, true))
        let labels = await screen.labels()
        #expect(labels.contains(text("composer.deviceOffline")), "\(labels)")
        let disabled = await screen.disabledLabels()
        #expect(disabled.contains(text("composer.send")) && disabled.contains(text("composer.stop")), "\(disabled)")
    }

    @Test("轮末没发出去的：说明几条未发送，给恢复为草稿与丢弃")
    func dropped() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        await model.turnEnded(normally: false)
        let view = ComposerView(model: model, contextUsage: usage, onDeleted: {})
        let labels = await HostedScreen(view).labels()
        #expect(labels.contains(text("composer.dropped %lld", 1)), "\(labels)")
        #expect(labels.contains(text("composer.restore")) && labels.contains(text("composer.discard")))
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 9, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("上一轮的未发送还没处置、这一轮又排着几条：两段都在，排着的照样看得见、撤得掉")
    func droppedAndQueued() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        await model.turnEnded(normally: false)
        model.turnStarted()
        model.text = "b"
        await model.send()
        let view = ComposerView(model: model, contextUsage: usage, onDeleted: {})
        let labels = await HostedScreen(view).labels()
        #expect(labels.contains(text("composer.dropped %lld", 1)), "\(labels)")
        #expect(labels.contains(text("composer.queued %lld", 1)), "\(labels)")
        #expect(labels.contains("b"))
        #expect(labels.contains(text("composer.cancelQueued")))
        let report = await hitTargetReport(of: view)
        // 常驻 7 块 + 停止本轮 + 恢复 + 丢弃 + 那一条的撤回。
        #expect(report.targets.count == 11, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("斜杠候选就地出现在输入框上方，每条一块命中区")
    func slashCandidates() async throws {
        let relay = FakeComposerRelay()
        await relay.set(skills: [ComposerSkillSource(name: "deploy", description: "上线")])
        let model = composer(relay: relay)
        model.edit(text: "/", cursor: 1)
        try await eventually("skills") { model.candidates.count == 2 }
        let view = ComposerView(model: model, contextUsage: usage, onDeleted: {})
        let labels = await HostedScreen(view).labels()
        #expect(labels.contains { $0.contains("/deploy") }, "\(labels)")
        #expect(labels.contains { $0.contains(text("composer.slash.compact")) })
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 9, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("更多面板：权限模式、模型、思考档位逐行标注当前取值，另有会话信息、上下文、删除会话；6 块命中区")
    func panel() async throws {
        let model = composer()
        await model.load()
        let view = ComposerPanel(model: model, contextUsage: usage, onDeleted: {})
        let labels = await HostedScreen(view).labels()
        // 每一行是一个可点元素：名称与它的当前取值同在一行。
        func row(_ title: String, _ value: String? = nil) -> Bool {
            labels.contains { $0.hasPrefix(text(title)) && (value.map($0.contains) ?? true) }
        }
        #expect(row("composer.permissionMode", "acceptEdits"), "\(labels)")
        #expect(row("composer.model", "claude-sonnet"), "\(labels)")
        #expect(row("composer.effort", "high"), "\(labels)")
        #expect(row("composer.context", text("composer.contextPercent %lld", 40)), "\(labels)")
        #expect(row("composer.sessionInfo") && row("composer.delete"), "\(labels)")
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 6, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("面板里的思考档位：会话行没设定时标注默认")
    func panelDefaultEffort() async throws {
        var settings = FakeSettingsSource()
        settings.settings.reasoningEffort = ""
        let model = composer(settings: settings)
        await model.load()
        let labels = await HostedScreen(ComposerPanel(model: model, contextUsage: usage, onDeleted: {})).labels()
        #expect(labels.contains { $0.hasPrefix(text("composer.effort")) && $0.contains(text("composer.effort.default")) }, "\(labels)")
    }

    @Test("权限模式一页：列出可选档位，当前档打勾；每档一块命中区外加返回")
    func permissionPage() async throws {
        let model = composer()
        await model.load()
        let view = ComposerPanel(model: model, contextUsage: usage, initialPage: .permissionMode, onDeleted: {})
        let labels = await HostedScreen(view).labels()
        for mode in ["default", "acceptEdits", "plan"] { #expect(labels.contains { $0.contains(mode) }, "\(mode)") }
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 4, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("会话信息一页：标题、机器指纹、工作目录、后端（机器产出的以原样呈现）")
    func infoPage() async throws {
        let model = composer()
        let view = ComposerPanel(model: model, contextUsage: usage, initialPage: .sessionInfo, onDeleted: {})
        let labels = await HostedScreen(view).labels()
        for fact in ["修构建", "fp-mini", "/srv/app", "claudecode", "conv-1"] { #expect(labels.contains(fact), "\(fact) in \(labels)") }
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 1, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("上下文一页：只给已用与上限的绝对值")
    func contextPage() async throws {
        let model = composer()
        let labels = await HostedScreen(ComposerPanel(model: model, contextUsage: usage, initialPage: .context, onDeleted: {})).labels()
        #expect(labels.contains(40_000.formatted()) && labels.contains(100_000.formatted()), "\(labels)")
    }
}
