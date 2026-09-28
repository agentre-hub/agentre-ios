import AgentreDomain
@testable import AgentreUI
import Testing

/// 输入区的视图模型：发送与排队、轮末接续、就地触发、面板三项的切换与删除会话。
@MainActor
@Suite("输入区模型")
struct ComposerModelTests {
    // MARK: 发送与排队

    @Test("空闲时发送：开新一轮，输入框清空")
    func idleSendRuns() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.text = "修构建"
        await model.send()
        #expect(await relay.calls == [.run("修构建", compact: false)])
        #expect(model.text.isEmpty)
    }

    @Test("一轮运行中：输入框不禁用，发送进入队列（插话），不开新一轮；应答带回句柄后可撤")
    func runningSendQueues() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "顺便看下测试"
        #expect(model.canSend)
        await model.send()
        #expect(await relay.calls == [.steer(queuedID: "local-1", text: "顺便看下测试")])
        #expect(model.text.isEmpty)
        #expect(model.queue.items == [QueuedSteer(id: "exec-local-1", text: "顺便看下测试", cancellable: true, pending: false)])
        // 还能接着排下一条。
        model.text = "再一条"
        #expect(model.canSend)
    }

    @Test("插话在飞时这一轮收场、插话随后又没发出去：那句话只回到输入框一处，不同时留在「未发送」里")
    func failedSteerAfterTurnEndIsNotDuplicated() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "顺便看下测试"
        await relay.holdNextSteer()
        let sending = Task { await model.send() }
        await relay.waitForHeldSteer()
        await model.turnEnded(normally: false)
        await relay.fail("steer")
        await relay.releaseSteer()
        await sending.value
        #expect(model.text == "顺便看下测试")
        #expect(model.queue.dropped.isEmpty)
        #expect(model.queue.items.isEmpty)
    }

    @Test("面板三项的当前取值：模型与思考档位取自会话行，权限档位与可选范围取自执行端与引擎目录")
    func settingsForConversation() {
        var saved = conversation()
        saved.providerKey = "anthropic"
        saved.modelKey = "claude-opus"
        saved.reasoningEffort = "high"
        let models = [ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus")]
        let settings = ComposerSettings(conversation: saved, permissionMode: "plan", permissionModes: ["default", "plan"], models: models)
        #expect(settings.model == ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus"))
        #expect(settings.reasoningEffort == "high")
        #expect(settings.permissionMode == "plan")
        #expect(settings.permissionModes == ["default", "plan"])
        #expect(settings.models == models)
        // 会话行上没有模型：不编一个当前值。
        #expect(ComposerSettings(conversation: conversation(), permissionMode: "", permissionModes: [], models: models).model == nil)
    }

    @Test("会话行上的当前模型按两枚键在引擎目录里认出，带上可读名；目录里没有它时只剩键")
    func currentModelResolvedFromCatalog() {
        var saved = conversation()
        saved.providerKey = "relay"
        saved.modelKey = "9f1c2e7a-0000-4000-8000-000000000004"
        let settings = ComposerSettings(conversation: saved, permissionMode: "", permissionModes: [], models: namedCatalog)
        #expect(settings.model == namedCatalog[3])
        #expect(settings.model?.displayName == "Opus")
        #expect(settings.model?.label == "Relay · Opus")
        saved.modelKey = "gone"
        let missing = ComposerSettings(conversation: saved, permissionMode: "", permissionModes: [], models: namedCatalog)
        #expect(missing.model == ComposerModelChoice(providerKey: "relay", modelKey: "gone"))
        #expect(missing.model?.label == "relay · gone", "查不到时如宿主 resolveTargetLabel 回落原始两枚键")
    }

    @Test("模型的可读名：name → modelId → modelKey")
    func modelDisplayName() {
        #expect(namedCatalog.map(\.displayName) == ["Opus", "claude-sonnet-4-5", "9f1c2e7a-0000-4000-8000-000000000003", "Opus"])
        #expect(ComposerModelChoice(providerKey: "", modelKey: "k").label == "k", "没有供应商时不带前缀")
    }

    @Test("选一个有名字的模型：下发的仍是供应商键与模型键")
    func selectingNamedModelSendsKeys() async throws {
        let relay = FakeComposerRelay()
        var settings = FakeSettingsSource()
        settings.settings.models = namedCatalog
        let model = composer(relay: relay, settings: settings)
        await model.load()
        await model.setModel(namedCatalog[3])
        #expect(await relay.calls == [.model("relay", "9f1c2e7a-0000-4000-8000-000000000004")])
        #expect(model.settings?.model == namedCatalog[3])
    }

    @Test("一轮运行中可以停止本轮：发出 runtimeAbort；停的调用在飞时不重复发")
    func stopsRunningTurn() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        #expect(!model.canStop, "闲着的时候没有什么可停")
        model.turnStarted()
        #expect(model.canStop)
        await relay.holdNextAbort()
        let first = Task { await model.stop() }
        await relay.waitForHeldAbort()
        #expect(!model.canStop, "停的调用在飞")
        await model.stop()
        await relay.releaseAbort()
        await first.value
        #expect(await relay.calls == [.abort])
        #expect(model.canStop, "停没停下来由这一轮的收场帧说话，不在这里猜")
        await model.turnEnded(normally: false)
        #expect(!model.canStop)
    }

    @Test("停不下来不另开一条错误面：这一轮照常在跑，还能再停")
    func stopFailureIsSilent() async throws {
        let relay = FakeComposerRelay()
        await relay.fail("abort")
        let model = composer(relay: relay)
        model.turnStarted()
        await model.stop()
        #expect(model.failure == nil)
        #expect(model.canStop)
    }

    @Test("排队的插话没排进去：从队列拿掉，字还回输入框")
    func steerFails() async throws {
        let relay = FakeComposerRelay()
        await relay.fail("steer")
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "等一下"
        await model.send()
        #expect(model.queue.items.isEmpty)
        #expect(model.text == "等一下")
        #expect(model.failure == .send)
    }

    @Test("开新一轮被机器拒了（或问机器也没有这句）：如实说没发出，字还回输入框")
    func runFails() async throws {
        let relay = FakeComposerRelay()
        await relay.fail("run")
        let model = composer(relay: relay)
        model.text = "写个 Kotlin"
        await model.send()
        #expect(model.failure == .send)
        #expect(model.text == "写个 Kotlin")
        #expect(!model.isTurnRunning)
    }

    @Test("应答丢了、问机器才知道它受理了且这一轮还在跑：不说没发出、不还字，就是运行中（可停）")
    func confirmedRunningTurn() async throws {
        let relay = FakeComposerRelay()
        await relay.set(runReceipt: .confirmed(lifecycle: "running"))
        let model = composer(relay: relay)
        model.text = "写个 Kotlin"
        await model.send()
        #expect(model.failure == nil)
        #expect(model.text.isEmpty)
        #expect(model.canStop)
    }

    @Test("应答丢了、问机器才知道它受理了且这一轮已经收场：不说没发出、不还字，不在运行，下一句直接开新一轮")
    func confirmedEndedTurn() async throws {
        let relay = FakeComposerRelay()
        await relay.set(runReceipt: .confirmed(lifecycle: "idle"))
        let model = composer(relay: relay)
        model.text = "写个 Kotlin"
        await model.send()
        #expect(model.failure == nil)
        #expect(model.text.isEmpty)
        #expect(!model.canStop)
        await relay.set(runReceipt: .acknowledged)
        model.text = "再来一个"
        #expect(model.canSend)
        await model.send()
        #expect(await relay.calls == [.run("写个 Kotlin", compact: false), .run("再来一个", compact: false)])
    }

    @Test("应答丢了、机器受理了但问不出它此刻在不在跑：不说没发出、不还字，运行态照转录说的不动")
    func confirmedTurnOfUnknownLifecycle() async throws {
        let relay = FakeComposerRelay()
        await relay.set(runReceipt: .confirmed(lifecycle: nil))
        let model = composer(relay: relay)
        model.text = "写个 Kotlin"
        await model.send()
        #expect(model.failure == nil)
        #expect(model.text.isEmpty)
        #expect(!model.canStop)
    }

    @Test("轮末接续那一轮应答丢了：开轮帧已递到、收场帧随连接丢了，机器说已收场——按那一次收场落定，不停在运行中")
    func continuationConfirmedEnded() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        await relay.set(drained: [ComposerConsumedSteer(queuedID: "exec-local-1", text: "a")])
        await relay.set(runReceipt: .confirmed(lifecycle: SavedConversation.Lifecycle.idle))
        await relay.holdNextRun()
        let ending = Task { await model.turnEnded(normally: true) }
        await relay.waitForHeldRun()
        // 接续那一轮的开轮帧先于应答递到；此后连接断了，重连后的清单对齐赶上开新一轮在飞，不作数。
        model.turnStarted()
        await model.reconcile(lifecycle: SavedConversation.Lifecycle.idle)
        await relay.set(drained: [])
        await relay.releaseRun()
        await ending.value
        #expect(!model.isTurnRunning)
        #expect(!model.canStop)
        #expect(model.failure == nil)
    }

    @Test("空白消息不发")
    func blankNotSent() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.text = "  \n"
        #expect(!model.canSend)
        await model.send()
        #expect(await relay.calls.isEmpty)
    }

    @Test("后端取走了一条：它从队列里消失")
    func consumed() async throws {
        let model = composer()
        model.turnStarted()
        model.text = "a"
        await model.send()
        model.steersConsumed([ComposerConsumedSteer(queuedID: "exec-local-1", text: "a")])
        #expect(model.queue.items.isEmpty)
    }

    @Test("撤回一条：按执行端句柄撤，撤掉即消失")
    func cancel() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        await model.cancelQueued("exec-local-1")
        #expect(await relay.calls.last == .cancel("exec-local-1"))
        #expect(model.queue.items.isEmpty)
    }

    @Test("撤回失败：这条留在原位、转成撤不掉")
    func cancelRefused() async throws {
        let relay = FakeComposerRelay()
        await relay.fail("cancel")
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        await model.cancelQueued("exec-local-1")
        #expect(model.queue.items == [QueuedSteer(id: "exec-local-1", text: "a", cancellable: false, pending: false)])
    }

    @Test("一轮正常收场：问执行端信箱里还剩什么，取回的几条空一行合并成下一轮")
    func turnEndContinues() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        model.text = "b"
        await model.send()
        await relay.set(drained: [ComposerConsumedSteer(queuedID: "exec-local-1", text: "a"), ComposerConsumedSteer(queuedID: "exec-local-2", text: "b")])
        await model.turnEnded(normally: true)
        #expect(await relay.calls.suffix(2) == [.drain, .run("a\n\nb", compact: false)])
        #expect(model.queue.items.isEmpty)
        #expect(model.queue.dropped.isEmpty)
        #expect(!model.isTurnRunning)
    }

    @Test("承载机不答信箱这一问：还排着的挪进「未发送」，可恢复为草稿")
    func turnEndUndrainable() async throws {
        let relay = FakeComposerRelay()
        await relay.set(drained: nil)
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        await model.turnEnded(normally: true)
        #expect(model.queue.dropped.map(\.text) == ["a"])
        #expect(await !relay.calls.contains(.run("a", compact: false)))
        model.text = "已有"
        model.restoreDropped()
        #expect(model.text == "已有\n\na")
        #expect(model.queue.dropped.isEmpty)
    }

    @Test("出错或中断的一轮：不问信箱、不接续，还排着的挪进「未发送」；丢弃即清掉")
    func turnAborted() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        await model.turnEnded(normally: false)
        #expect(await !relay.calls.contains(.drain))
        #expect(model.queue.dropped.map(\.text) == ["a"])
        model.discardDropped()
        #expect(model.queue.dropped.isEmpty)
    }

    @Test("非 claudecode 的后端上 /compact 转成一次压缩调用，不当普通消息发")
    func compact() async throws {
        let relay = FakeComposerRelay()
        let model = composer(backend: "codex", relay: relay)
        model.text = "/compact"
        await model.send()
        #expect(await relay.calls == [.run("/compact", compact: true)])
        let native = FakeComposerRelay()
        let claude = composer(backend: "claudecode", relay: native)
        claude.text = "/compact"
        await claude.send()
        #expect(await native.calls == [.run("/compact", compact: false)])
    }

    @Test("不摆 /compact 的后端（hermes、未知）上照原文发出，不发一次对端不认的压缩调用", arguments: ["hermes", "openclaw", ""])
    func compactOnlyWhereOffered(_ backend: String) async throws {
        let relay = FakeComposerRelay()
        let model = composer(backend: backend, relay: relay)
        model.text = "/compact"
        await model.send()
        #expect(await relay.calls == [.run("/compact", compact: false)])
    }

    @Test("轮末接续还在路上：此时点发送不另开一轮，接续那一轮开起来之前发送不可用")
    func sendDuringContinuation() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        await relay.set(drained: [ComposerConsumedSteer(queuedID: "exec-local-1", text: "a")])
        await relay.holdNextDrain()
        let ending = Task { await model.turnEnded(normally: true) }
        await relay.waitForHeldDrain()

        model.text = "b"
        #expect(!model.canSend)
        await model.send()
        await relay.releaseDrain()
        await ending.value

        #expect(await relay.calls.filter { if case .run = $0 { true } else { false } } == [.run("a", compact: false)])
        #expect(model.text == "b")
        #expect(model.canSend)
    }

    // MARK: 收场帧没递到：按机器此刻的会话状态对齐

    @Test("以为在跑、机器说已正常收场（后台期间结束的一轮）：不再运行，问一次信箱，剩下的接续一次")
    func reconcileEndedTurn() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        await relay.set(drained: [ComposerConsumedSteer(queuedID: "exec-local-1", text: "a")])
        await model.reconcile(lifecycle: SavedConversation.Lifecycle.idle)
        #expect(!model.isTurnRunning)
        #expect(!model.canStop)
        #expect(await relay.calls.suffix(2) == [.drain, .run("a", compact: false)])
        #expect(model.queue.items.isEmpty)
        #expect(model.queue.dropped.isEmpty)
    }

    @Test("机器说还在跑：照旧在跑、不问信箱；已经不在跑时再对齐一次（反复回前台）什么也不做")
    func reconcileNoChange() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        await model.reconcile(lifecycle: SavedConversation.Lifecycle.running)
        #expect(model.canStop)
        await model.reconcile(lifecycle: SavedConversation.Lifecycle.idle)
        await model.reconcile(lifecycle: SavedConversation.Lifecycle.idle)
        #expect(await relay.calls == [.drain])
    }

    @Test("机器说这一轮以故障收场或被中断：不再运行，不问信箱，还排着的挪进「未发送」",
          arguments: [SavedConversation.Lifecycle.failed, SavedConversation.Lifecycle.interrupted])
    func reconcileFailedTurn(_ lifecycle: String) async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.text = "a"
        await model.send()
        await model.reconcile(lifecycle: lifecycle)
        #expect(!model.canStop)
        #expect(await !relay.calls.contains(.drain))
        #expect(model.queue.dropped.map(\.text) == ["a"])
    }

    @Test("对齐收掉的那一轮，它迟到的收场帧不再问一次信箱；下一轮开起来之后的收场照常接续")
    func lateEndAfterReconcile() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        await model.reconcile(lifecycle: SavedConversation.Lifecycle.idle)
        await model.turnEnded(normally: true)
        #expect(await relay.calls == [.drain])
        model.turnStarted()
        await model.turnEnded(normally: true)
        #expect(await relay.calls == [.drain, .drain])
    }

    @Test("开新一轮的调用在飞时机器的状态不作数：那一刻的快照可能早于这一轮，不据它收场、不问信箱")
    func reconcileWhileStarting() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.text = "x"
        await relay.holdNextRun()
        let sending = Task { await model.send() }
        await relay.waitForHeldRun()
        model.turnStarted()
        await model.reconcile(lifecycle: SavedConversation.Lifecycle.idle)
        await relay.releaseRun()
        await sending.value
        #expect(model.canStop)
        #expect(await relay.calls == [.run("x", compact: false)])
    }

    // MARK: 斜杠命令

    @Test("键入 / 就地给出候选；Skill 目录按这条会话要（承载机由适配器解析），按会话工作目录解析")
    func slashCandidates() async throws {
        let relay = FakeComposerRelay()
        await relay.set(skills: [ComposerSkillSource(name: "deploy", description: "上线")])
        let model = composer(relay: relay)
        model.edit(text: "/", cursor: 1)
        try await eventually("skills") { model.candidates.count == 2 }
        #expect(await relay.calls == [.skills(key, backend: "claudecode", cwd: "/srv/app")])
        #expect(model.candidates.map(\.title) == ["/compact", "/deploy"])
        model.edit(text: "/dep", cursor: 4)
        #expect(model.candidates.map(\.title) == ["/deploy"])
        model.select(model.candidates[0])
        #expect(model.text == "/deploy ")
        #expect(model.cursor == 8)
        #expect(model.candidates.isEmpty)
        // 目录只要一次。
        model.edit(text: "/deploy /", cursor: 9)
        #expect(await relay.calls.count == 1)
    }

    @Test("Skill 目录要不到：候选只剩内置命令，输入照常")
    func slashSkillsFail() async throws {
        let relay = FakeComposerRelay()
        await relay.fail("skills")
        let model = composer(relay: relay)
        model.edit(text: "看 /", cursor: 3)
        try await eventually("asked") { await relay.calls.count == 1 }
        #expect(model.candidates.map(\.title) == ["/compact"])
    }

    @Test("Skill 目录一时要不到：下一次键入触发再问，要到了就列出来")
    func slashSkillsRetry() async throws {
        let relay = FakeComposerRelay()
        await relay.fail("skills")
        await relay.set(skills: [ComposerSkillSource(name: "deploy", description: "上线")])
        let model = composer(relay: relay)
        model.edit(text: "看 /", cursor: 3)
        try await eventually("asked") { await relay.calls.count == 1 }
        await relay.succeed("skills")
        model.edit(text: "看 /d", cursor: 4)
        try await eventually("asked again") { model.candidates.map(\.title).contains("/deploy") }
    }

    @Test("没发出去的草稿还回输入框时，就地候选按还回后的正文重算：选中不会把还回的那段吞掉")
    func restoreRecomputesTrigger() async throws {
        let relay = FakeComposerRelay()
        await relay.holdNextRun()
        await relay.fail("run")
        let model = composer(relay: relay)
        model.text = "hello"
        let sending = Task { await model.send() }
        await relay.waitForHeldRun()
        model.edit(text: "/co", cursor: 3)
        await relay.releaseRun()
        await sending.value
        #expect(model.text == "hello\n\n/co")
        let candidate = try #require(model.candidates.first { $0.title == "/compact" })
        model.select(candidate)
        #expect(model.text == "hello\n\n/compact ")
    }

    @Test("光标离开触发位：候选收起")
    func slashDismiss() async throws {
        let model = composer()
        model.edit(text: "/co", cursor: 3)
        #expect(!model.candidates.isEmpty)
        model.edit(text: "/co x", cursor: 5)
        #expect(model.candidates.isEmpty)
    }

    // MARK: 提及

    @Test("键入 @ 就地给出 Agent 与设备候选；选中后正文以提及 XML 发出")
    func mentions() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.edit(text: "请 @re", cursor: 5)
        try await eventually("mentions") { !model.candidates.isEmpty }
        #expect(model.candidates.map(\.title) == ["reviewer", "writer"])
        model.select(model.candidates[0])
        #expect(model.text == "请 @reviewer ")
        model.text += "看下"
        await model.send()
        #expect(await relay.calls == [.run(#"请 <agent id="7">reviewer</agent> 看下"#, compact: false)])
    }

    @Test("插话里的提及：这一轮中断、挪进「未发送」后恢复再发，正文仍以提及 XML 发出")
    func restoredDropKeepsMentions() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.turnStarted()
        model.edit(text: "请 @re", cursor: 5)
        try await eventually("mentions") { !model.candidates.isEmpty }
        model.select(model.candidates[0])
        model.text += "看下"
        await model.send()
        await model.turnEnded(normally: false)
        #expect(model.queue.dropped.count == 1)
        model.restoreDropped()
        #expect(model.text == "请 @reviewer 看下")
        await model.send()
        #expect(await relay.calls.last == .run(#"请 <agent id="7">reviewer</agent> 看下"#, compact: false))
    }

    // MARK: 面板三项

    @Test("载入这条会话的三项当前取值；切换经中继写入，成功后面板标注新值")
    func settings() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        await model.load()
        #expect(model.settings == sampleSettings)
        model.turnStarted()
        await relay.startTurn()
        await model.setPermissionMode("plan")
        await model.setModel(ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus"))
        await model.setReasoningEffort("max")
        #expect(await relay.calls == [.permission("plan"), .model("anthropic", "claude-opus"), .effort("max")])
        #expect(model.settings?.permissionMode == "plan")
        #expect(model.settings?.model?.modelKey == "claude-opus")
        #expect(model.settings?.reasoningEffort == "max")
    }

    @Test("两轮之间切档：只改本机当前档、不去问执行端也不报失败；下一轮与轮末接续的那一轮都带上它")
    func permissionModeBetweenTurns() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        await model.load()
        await model.setPermissionMode("plan")
        #expect(model.failure == nil)
        #expect(model.settings?.permissionMode == "plan")
        #expect(await relay.calls.isEmpty)

        model.edit(text: "go on", cursor: 5)
        await model.send()
        #expect(await relay.calls == [.run("go on", compact: false), .permission("plan")])
        #expect(await relay.runPermissionModes == ["plan"])

        // 这一轮收场、执行端摘掉会话；两轮之间再切一次，下一轮与它轮末接续的那一轮都带新档。
        model.turnStarted()
        await relay.finishTurn()
        await model.turnEnded(normally: true)
        await model.setPermissionMode("default")
        #expect(model.failure == nil)
        #expect(!(await relay.calls.contains(.permission("default"))))
        model.edit(text: "next", cursor: 4)
        await model.send()
        model.turnStarted()
        await relay.set(drained: [ComposerConsumedSteer(queuedID: "q", text: "and lint")])
        await relay.finishTurn()
        await model.turnEnded(normally: true)
        #expect(model.failure == nil)
        #expect(await relay.runPermissionModes == ["plan", "default", "default"])
    }

    @Test("面板还没载入：发送照常，不带档位（执行端按默认档跑），也没有档可补发")
    func permissionModeUnknown() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.edit(text: "go on", cursor: 5)
        await model.send()
        #expect(await relay.runPermissionModes == [""])
        #expect(await relay.calls == [.run("go on", compact: false)])
    }

    // MARK: 每一轮被接受后补发当前档（执行进程被复用时 runtime.run 带的档不生效）

    @Test("两轮之间切档后的下一轮：上一轮的执行进程被复用、run 带的新档不生效；被接受后补发，实际按新档跑")
    func supplementAfterSwitchBetweenTurns() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        await model.load()
        model.edit(text: "go on", cursor: 5)
        await model.send()
        #expect(await relay.executorMode == "acceptEdits")
        model.turnStarted()
        await relay.finishTurn()
        await model.turnEnded(normally: false)

        await model.setPermissionMode("plan")
        model.edit(text: "next", cursor: 4)
        await model.send()
        #expect(await relay.runPermissionModes == ["acceptEdits", "plan"])
        #expect(await relay.executorMode == "plan")
        #expect(model.failure == nil)
    }

    @Test("没切过档也补发：池里的进程是按别的档起的（别的端、App 重启之前），被接受后纠正成本机当前档")
    func supplementWithoutSwitch() async throws {
        let relay = FakeComposerRelay()
        await relay.launchExecutor(mode: "default")
        let model = composer(relay: relay)
        await model.load()
        model.edit(text: "go on", cursor: 5)
        await model.send()
        #expect(await relay.executorMode == "acceptEdits")
        #expect(model.failure == nil)
    }

    @Test("排队取回合并后发出的那一轮同样补发：接续那一轮复用别的端按旧档起的进程，被接受后按本机当前档跑")
    func supplementAfterContinuation() async throws {
        let relay = FakeComposerRelay()
        await relay.launchExecutor(mode: "default")
        await relay.startTurn()
        let model = composer(relay: relay)
        await model.load()
        model.turnStarted()
        model.text = "a"
        await model.send()
        await relay.set(drained: [ComposerConsumedSteer(queuedID: "exec-local-1", text: "a")])
        await relay.finishTurn()
        await model.turnEnded(normally: true)
        #expect(await relay.calls.suffix(3) == [.drain, .run("a", compact: false), .permission("acceptEdits")])
        #expect(await relay.executorMode == "acceptEdits")
        #expect(model.failure == nil)
    }

    @Test("轮末接续那一轮的补发在飞时切档：那一轮的开轮帧要等这里落定才递得进来，此刻只改得了本机；补发回来后按新档再补一次，机器实际按新档跑")
    func switchWhileContinuationSupplementInFlight() async throws {
        let relay = FakeComposerRelay()
        await relay.launchExecutor(mode: "default")
        await relay.startTurn()
        let model = composer(relay: relay)
        await model.load()
        model.turnStarted()
        model.text = "a"
        await model.send()
        await relay.set(drained: [ComposerConsumedSteer(queuedID: "exec-local-1", text: "a")])
        await relay.finishTurn()
        await relay.holdPermissions()
        let ending = Task { await model.turnEnded(normally: true) }
        try await eventually("supplement in flight") { await relay.heldPermissions == 1 }
        await model.setPermissionMode("plan")
        await relay.releasePermissions()
        await ending.value
        #expect(await relay.executorMode == "plan")
        #expect(model.settings?.permissionMode == "plan")
        #expect(model.failure == nil)
    }

    @Test("补发在飞时切档、开轮帧随后到了再切一次：补发回来之前都只改本机，回来后按最新那一档再补——不与补发交错另发，再补的那一次也盖不掉更新的选择")
    func switchWhileSupplementInFlightThenTurnStarted() async throws {
        let relay = FakeComposerRelay()
        await relay.launchExecutor(mode: "default")
        let model = composer(relay: relay)
        await model.load()
        model.text = "go on"
        await relay.holdPermissions()
        let sending = Task { await model.send() }
        try await eventually("supplement in flight") { await relay.heldPermissions == 1 }
        await model.setPermissionMode("plan")
        model.turnStarted()
        let switching = Task { await model.setPermissionMode("default") }
        // 改完了本机，或者已经递到执行端、应答在路上。
        try await eventually("the switch is made") {
            if model.settings?.permissionMode == "default" { return true }
            return await relay.calls.last == .permission("default")
        }
        await relay.releasePermission()
        await relay.releasePermissions()
        await sending.value
        await switching.value
        #expect(await relay.executorMode == "default")
        #expect(model.settings?.permissionMode == "default")
        #expect(model.failure == nil)
    }

    @Test("补发在飞时切档、再补没成：切的时候这一轮已在跑，那一次就是一轮在跑时切档——如实说没改成、面板退回执行端上那一档；开轮帧还没到时切的同两轮之间，不提示")
    func switchWhileSupplementInFlightThenResendFails() async throws {
        for running in [true, false] {
            let relay = FakeComposerRelay()
            await relay.launchExecutor(mode: "default")
            let model = composer(relay: relay)
            await model.load()
            model.text = "go on"
            await relay.holdPermissions()
            let sending = Task { await model.send() }
            try await eventually("supplement in flight") { await relay.heldPermissions == 1 }
            if running { model.turnStarted() }
            await model.setPermissionMode("plan")
            #expect(model.failure == nil)
            await relay.fail("permission")
            await relay.releasePermissions()
            await sending.value
            #expect(await relay.calls == [.run("go on", compact: false), .permission("acceptEdits"), .permission("plan")])
            #expect(await relay.executorMode == "acceptEdits")
            #expect(model.failure == (running ? .change : nil))
            #expect(model.settings?.permissionMode == (running ? "acceptEdits" : "plan"))
        }
    }

    @Test("补发失败不提示、不改变这次发送的结果：不说没发出、不还字、不说没改成，面板照旧，还能接着发")
    func supplementFailureIsSilent() async throws {
        let relay = FakeComposerRelay()
        await relay.launchExecutor(mode: "default")
        await relay.fail("permission")
        let model = composer(relay: relay)
        await model.load()
        model.edit(text: "go on", cursor: 5)
        await model.send()
        #expect(await relay.calls == [.run("go on", compact: false), .permission("acceptEdits")])
        #expect(model.failure == nil)
        #expect(model.text.isEmpty)
        #expect(model.settings?.permissionMode == "acceptEdits")
        model.edit(text: "next", cursor: 4)
        #expect(model.canSend)
    }

    @Test("应答丢了、靠问机器才确认受理的那一轮不补发", arguments: [SavedConversation.Lifecycle.running, SavedConversation.Lifecycle.idle])
    func noSupplementForConfirmedTurn(_ lifecycle: String) async throws {
        let relay = FakeComposerRelay()
        await relay.set(runReceipt: .confirmed(lifecycle: lifecycle))
        let model = composer(relay: relay)
        await model.load()
        model.edit(text: "go on", cursor: 5)
        await model.send()
        #expect(await relay.calls == [.run("go on", compact: false)])
        #expect(model.failure == nil)
    }

    @Test("开新一轮的调用在飞时切档：只改本机当前档，被接受后随补发生效——不另发一次、也不被补发的旧档盖掉")
    func switchWhileRunInFlight() async throws {
        let relay = FakeComposerRelay()
        await relay.launchExecutor(mode: "default")
        let model = composer(relay: relay)
        await model.load()
        model.text = "go on"
        await relay.holdNextRun()
        let sending = Task { await model.send() }
        await relay.waitForHeldRun()
        // agentred 在应答之前就推了开轮帧（runtime.go:571-593）：输入区此刻已是运行中。
        model.turnStarted()
        await model.setPermissionMode("plan")
        #expect(model.failure == nil)
        #expect(model.settings?.permissionMode == "plan")
        await relay.releaseRun()
        await sending.value
        #expect(await relay.calls == [.run("go on", compact: false), .permission("plan")])
        #expect(await relay.executorMode == "plan")
    }

    @Test("开新一轮的调用在飞时切档、应答又丢了：问机器确认这一轮还在跑，就是一轮在跑时切档——即刻让它生效，没改成如实说、面板退回这一轮带的档")
    func switchWhileRunInFlightThenAnswerLost() async throws {
        for failing in [false, true] {
            let relay = FakeComposerRelay()
            await relay.set(runReceipt: .confirmed(lifecycle: SavedConversation.Lifecycle.running))
            if failing { await relay.fail("permission") }
            let model = composer(relay: relay)
            await model.load()
            model.text = "go on"
            await relay.holdNextRun()
            let sending = Task { await model.send() }
            await relay.waitForHeldRun()
            model.turnStarted()
            await model.setPermissionMode("plan")
            await relay.releaseRun()
            await sending.value
            #expect(await relay.calls == [.run("go on", compact: false), .permission("plan")])
            #expect(await relay.executorMode == (failing ? "acceptEdits" : "plan"))
            #expect(model.failure == (failing ? .change : nil))
            #expect(model.settings?.permissionMode == (failing ? "acceptEdits" : "plan"))
            #expect(model.isTurnRunning)
        }
    }

    @Test("开新一轮的调用在飞时切档、应答丢了而机器说这一轮已收场：那是两轮之间，只改本机，不去问执行端")
    func switchWhileRunInFlightThenAnswerLostAfterTheTurn() async throws {
        let relay = FakeComposerRelay()
        await relay.set(runReceipt: .confirmed(lifecycle: SavedConversation.Lifecycle.idle))
        let model = composer(relay: relay)
        await model.load()
        model.text = "go on"
        await relay.holdNextRun()
        let sending = Task { await model.send() }
        await relay.waitForHeldRun()
        model.turnStarted()
        await model.setPermissionMode("plan")
        await relay.releaseRun()
        await sending.value
        #expect(await !relay.calls.contains(.permission("plan")))
        #expect(model.failure == nil)
        #expect(model.settings?.permissionMode == "plan")
    }

    @Test("一轮在跑时切档：额外让执行端即刻换档；它答没有进行中的一轮时如实说没改成、面板照旧，下一轮仍带原档")
    func permissionModeDuringATurn() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        await model.load()
        model.edit(text: "go on", cursor: 5)
        await model.send()
        model.turnStarted()
        await model.setPermissionMode("plan")
        #expect(await relay.calls.last == .permission("plan"))
        #expect(model.failure == nil)
        #expect(model.settings?.permissionMode == "plan")

        await relay.finishTurn()
        await model.setPermissionMode("default")
        #expect(await relay.calls.last == .permission("default"))
        #expect(model.failure == .change)
        #expect(model.settings?.permissionMode == "plan")

        await model.turnEnded(normally: false)
        model.edit(text: "next", cursor: 4)
        await model.send()
        #expect(await relay.runPermissionModes == ["acceptEdits", "plan"])
    }

    @Test("起手档位：转录里报过且在可选范围里的那一档，否则是执行端的默认档")
    func startingPermissionMode() {
        let allowed = ["default", "acceptEdits", "plan"]
        #expect(ComposerSettings.startingPermissionMode(reported: "plan", allowed: allowed, defaultMode: "default") == "plan")
        #expect(ComposerSettings.startingPermissionMode(reported: nil, allowed: allowed, defaultMode: "default") == "default")
        #expect(ComposerSettings.startingPermissionMode(reported: "", allowed: allowed, defaultMode: "default") == "default")
        #expect(ComposerSettings.startingPermissionMode(reported: "bypassPermissions", allowed: allowed, defaultMode: "default") == "default")
        #expect(ComposerSettings.startingPermissionMode(reported: "plan", allowed: [], defaultMode: "") == "")
    }

    @Test("选中的就是当前值：不写；写失败：保持原值并如实说没改成")
    func settingsNoopAndFailure() async throws {
        let relay = FakeComposerRelay()
        await relay.fail("effort")
        let model = composer(relay: relay)
        await model.load()
        await model.setPermissionMode("acceptEdits")
        #expect(await relay.calls.isEmpty)
        await model.setReasoningEffort("low")
        #expect(model.settings?.reasoningEffort == "high")
        #expect(model.failure == .change)
    }

    // MARK: 模型与思考档位随每一轮带过去（执行端只认 runtime.run 带的这几格）

    @Test("两轮之间切模型与思考档位：写下只供显示、机器照旧；下一轮 run 带上它们，机器实际按新模型与新档位跑")
    func modelAndEffortRideTheNextRun() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        await model.load()
        model.edit(text: "go on", cursor: 5)
        await model.send()
        #expect(await relay.effectiveModel == ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-sonnet"))
        #expect(await relay.effectiveEffort == "high")
        model.turnStarted()
        await relay.finishTurn()
        await model.turnEnded(normally: true)

        await model.setModel(ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus"))
        await model.setReasoningEffort("max")
        #expect(model.failure == nil)
        #expect(await relay.storedModel == ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus"))
        #expect(await relay.effectiveModel == ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-sonnet"))

        model.edit(text: "next", cursor: 4)
        await model.send()
        #expect(await relay.runSettings.last == ComposerRunSettings(
            permissionMode: "acceptEdits", providerKey: "anthropic", modelKey: "claude-opus", reasoningEffort: "max"
        ))
        #expect(await relay.effectiveModel == ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus"))
        #expect(await relay.effectiveEffort == "max")
    }

    @Test("排队取回合并后发出的那一轮同样带上当前的模型与思考档位（包括这一轮在跑时切的）")
    func continuationCarriesModelAndEffort() async throws {
        let relay = FakeComposerRelay()
        await relay.startTurn()
        let model = composer(relay: relay)
        await model.load()
        model.turnStarted()
        await model.setModel(ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus"))
        await model.setReasoningEffort("low")
        model.text = "a"
        await model.send()
        await relay.set(drained: [ComposerConsumedSteer(queuedID: "exec-local-1", text: "a")])
        await relay.finishTurn()
        await model.turnEnded(normally: true)
        #expect(await relay.calls.contains(.run("a", compact: false)))
        #expect(await relay.effectiveModel == ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus"))
        #expect(await relay.effectiveEffort == "low")
    }

    @Test("没钉模型、没设思考档位：两枚键与档位都留空，机器按 Agent 绑定与后端配置跑")
    func unsetModelAndEffortStayEmpty() async throws {
        let relay = FakeComposerRelay()
        var settings = FakeSettingsSource()
        settings.settings.model = nil
        settings.settings.reasoningEffort = ""
        let model = composer(relay: relay, settings: settings)
        await model.load()
        model.edit(text: "go on", cursor: 5)
        await model.send()
        #expect(await relay.runSettings == [ComposerRunSettings(permissionMode: "acceptEdits")])
        #expect(await relay.effectiveModel == ComposerModelChoice(providerKey: "", modelKey: ""))
        #expect(await relay.effectiveEffort == "")
    }

    @Test("会话钉了供应商、模型跟随它的默认（模型键空）：面板没有可标注的模型，run 仍带上供应商键——面板没载入时同样取自会话行")
    func pinnedProviderDefaultRides() async throws {
        let saved = conversation(providerKey: "relay", reasoningEffort: "medium")
        for loads in [true, false] {
            let relay = FakeComposerRelay()
            let model = composer(saved: saved, relay: relay, settings: FakeSettingsSource(settings: ComposerSettings(
                conversation: saved, permissionMode: "default", permissionModes: ["default"], models: namedCatalog
            )))
            if loads { await model.load() }
            model.edit(text: "go on", cursor: 5)
            await model.send()
            #expect(await relay.effectiveModel == ComposerModelChoice(providerKey: "relay", modelKey: ""), "loaded: \(loads)")
            #expect(await relay.effectiveEffort == "medium", "loaded: \(loads)")
        }
    }

    @Test("切模型没写成：面板照旧，下一轮仍带原来的模型")
    func failedModelSwitchDoesNotRide() async throws {
        let relay = FakeComposerRelay()
        await relay.fail("model")
        let model = composer(relay: relay)
        await model.load()
        await model.setModel(ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-opus"))
        #expect(model.failure == .change)
        model.edit(text: "go on", cursor: 5)
        await model.send()
        #expect(await relay.effectiveModel == ComposerModelChoice(providerKey: "anthropic", modelKey: "claude-sonnet"))
    }

    // MARK: 删除

    @Test("删除会话：机器上删掉，本地库也删掉，交回宿主")
    func delete() async throws {
        let relay = FakeComposerRelay()
        let store = FakeConversationStore()
        let model = composer(relay: relay, store: store)
        #expect(await model.deleteConversation())
        #expect(await relay.calls == [.delete])
        #expect(await store.deleted == [key])
    }

    @Test("机器上没删成：本地一条不动")
    func deleteFails() async throws {
        let relay = FakeComposerRelay()
        await relay.fail("delete")
        let store = FakeConversationStore()
        let model = composer(relay: relay, store: store)
        #expect(await !model.deleteConversation())
        #expect(await store.deleted.isEmpty)
        #expect(model.failure == .delete)
    }
}
