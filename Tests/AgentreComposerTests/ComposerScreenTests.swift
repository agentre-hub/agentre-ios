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
        // 上下文环在常驻行（工具行）：命中区补满 44 后，图标窄的按钮会比宽的环多探进两侧的留白，
        // 挑最靠右的那块未必是环——常驻行是这一屏最下面一行，挑最靠下的那块才稳。
        let ring = try #require(report.targets.max { $0.midY < $1.midY })
        #expect(report.targets.filter { abs($0.midY - ring.midY) < 1 }.count == 5)
    }

    @Test("App 内选的语言与系统不同、再切回：输入框的占位与读屏标签、斜杠命令的说明都随之换成那种语言")
    func followsInAppLanguage() async throws {
        let model = composer()
        let mismatches = await inAppLanguageMismatches(
            of: ComposerView(model: model, contextUsage: usage, onDeleted: {}), bundle: AgentreUIResources.bundle,
            copy: [("composer.message", "Composer")], partOfLabels: [("composer.slash.compact", "Composer")]
        ) { _ in
            // 候选按此刻的语言排出：每次切换后重新键入斜杠，候选行上的说明是那种语言。
            model.edit(text: "", cursor: 0)
            model.edit(text: "/", cursor: 1)
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
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

    @Test("更多面板：权限模式、模型、思考档位逐行标注人话取值，另有会话信息、上下文、删除会话；两组卡片共 6 块命中区")
    func panel() async throws {
        let model = composer()
        await model.load()
        let view = ComposerPanel(model: model, contextUsage: usage, onDeleted: {})
        let labels = await HostedScreen(view).labels()
        // 每一行是一个可点元素：名称与它的当前取值同在一行。
        func row(_ title: String, _ value: String? = nil) -> Bool {
            labels.contains { $0.hasPrefix(text(title)) && (value.map($0.contains) ?? true) }
        }
        // 权限模式与思考档位以人话呈现，不显示原串（规格「04 更多面板」）。
        #expect(row("composer.permissionMode", text("composer.permissionMode.acceptEdits")), "\(labels)")
        #expect(!labels.contains { $0.hasPrefix(text("composer.permissionMode")) && $0.contains("acceptEdits") }, "\(labels)")
        // 模型只写模型名，不带供应商前缀。
        #expect(row("composer.model", "claude-sonnet"), "\(labels)")
        #expect(row("composer.effort", text("composer.effort.high")), "\(labels)")
        // 上下文写「已用k/上限k」，不再是百分比。
        #expect(row("composer.context", "40k/100k"), "\(labels)")
        #expect(row("composer.sessionInfo") && row("composer.delete"), "\(labels)")
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 6, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("更多面板会话信息行：写承载机器此刻的呈现名")
    func panelSessionInfoMachineName() async throws {
        let model = composer(identity: StubIdentityDirectory(name: "mac-studio"))
        await model.load()
        let labels = await HostedScreen(ComposerPanel(model: model, contextUsage: usage, onDeleted: {})).labels()
        #expect(labels.contains { $0.hasPrefix(text("composer.sessionInfo")) && $0.contains("mac-studio") }, "\(labels)")
    }

    @Test("更多面板思考档位：低/中/高换成人话，执行端报出的更高档原样等宽")
    func panelReasoningEffortDisplay() async throws {
        var settings = FakeSettingsSource()
        settings.settings.reasoningEffort = "xhigh"
        let model = composer(settings: settings)
        await model.load()
        let labels = await HostedScreen(ComposerPanel(model: model, contextUsage: usage, onDeleted: {})).labels()
        #expect(labels.contains { $0.hasPrefix(text("composer.effort")) && $0.contains("xhigh") }, "\(labels)")
    }

    @Test("模型一页：每行是可读名（name → modelId → modelKey），同名的按供应商分组、副行是模型 ID；UUID 形的键不上脸")
    func modelPage() async throws {
        var settings = FakeSettingsSource()
        settings.settings.models = namedCatalog
        settings.settings.model = namedCatalog[3]
        let model = composer(settings: settings)
        await model.load()
        let view = ComposerPanel(model: model, contextUsage: usage, initialPage: .model, onDeleted: {})
        let labels = await HostedScreen(view).labels()
        #expect(!labels.contains { $0.contains("9f1c2e7a-0000-4000-8000-000000000001") }, "有名字的不显示键：\(labels)")
        #expect(!labels.contains { $0.contains("9f1c2e7a-0000-4000-8000-000000000002") }, "有模型 ID 的不显示键：\(labels)")
        #expect(labels.filter { $0.hasPrefix("Opus") && $0.contains("claude-opus-4-1") }.count == 2, "\(labels)")
        #expect(labels.contains { $0.hasPrefix("claude-sonnet-4-5") }, "\(labels)")
        #expect(labels.contains { $0.hasPrefix("9f1c2e7a-0000-4000-8000-000000000003") }, "名字与 ID 都缺才用键：\(labels)")
        // 同名的两个 Opus 由供应商分组区分（宿主 model-target-picker 以供应商名为组头）。
        let anthropic = try #require(labels.firstIndex(of: "Anthropic"), "\(labels)")
        let relay = try #require(labels.firstIndex(of: "Relay"), "\(labels)")
        let opuses = labels.indices.filter { labels[$0].hasPrefix("Opus") }
        #expect(opuses.count == 2 && anthropic < opuses[0] && opuses[0] < relay && relay < opuses[1], "\(labels)")
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 5, "返回 + 四个模型：\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("根页的当前模型标注供应商与可读名，不标 UUID 形的键")
    func panelCurrentModelName() async throws {
        var settings = FakeSettingsSource()
        settings.settings.models = namedCatalog
        settings.settings.model = namedCatalog[0]
        let model = composer(settings: settings)
        await model.load()
        let labels = await HostedScreen(ComposerPanel(model: model, contextUsage: usage, onDeleted: {})).labels()
        // 只写模型名，不带供应商前缀（规格「04 更多面板」）。
        #expect(labels.contains { $0.hasPrefix(text("composer.model")) && $0.contains("Opus") }, "\(labels)")
        #expect(!labels.contains { $0.hasPrefix(text("composer.model")) && $0.contains("Anthropic") }, "\(labels)")
        #expect(!labels.contains { $0.contains("9f1c2e7a") }, "\(labels)")
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
        // 表内已知档位只写人话名，不附原串（规格「04 更多面板」）。
        for key in ["default", "acceptEdits", "plan"] {
            let human = text("composer.permissionMode.\(key)")
            #expect(labels.contains(human), "\(key) 人话 in \(labels)")
            #expect(!labels.contains { $0.contains(key) && !$0.contains("xhigh") }, "\(key) 不带原串：\(labels)")
        }
        let report = await hitTargetReport(of: view)
        #expect(report.targets.count == 4, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("权限模式一页：表外取值才原样（等宽）显示，表内已知档位不带原串")
    func permissionPageUnknownMode() async throws {
        var settings = FakeSettingsSource()
        settings.settings.permissionModes = ["default", "sudo"]
        let model = composer(settings: settings)
        await model.load()
        let labels = await HostedScreen(ComposerPanel(model: model, contextUsage: usage, initialPage: .permissionMode, onDeleted: {})).labels()
        #expect(labels.contains("sudo"), "\(labels)")
        #expect(labels.contains(text("composer.permissionMode.default")), "\(labels)")
        #expect(!labels.contains { $0.contains("default") && $0.contains(text("composer.permissionMode.default")) }, "\(labels)")
    }

    @Test("思考档位一页：低/中/高只写人话，不附原串；更高档原样")
    func effortPageNoRawStrings() async throws {
        let model = composer()
        await model.load()
        let labels = await HostedScreen(ComposerPanel(model: model, contextUsage: usage, initialPage: .effort, onDeleted: {})).labels()
        for key in ["low", "medium", "high"] {
            #expect(labels.contains(text("composer.effort.\(key)")), "\(key) in \(labels)")
            #expect(!labels.contains { $0.contains(key) && !$0.contains("xhigh") }, "\(key) 不带原串：\(labels)")
        }
        #expect(labels.contains("xhigh") && labels.contains("max"), "\(labels)")
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
