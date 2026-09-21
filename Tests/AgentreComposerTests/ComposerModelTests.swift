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

    @Test("一轮运行中可以停止本轮：发出 runtimeAbort；停的调用在飞时不重复发")
    func stopsRunningTurn() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        #expect(!model.canStop, "闲着的时候没有什么可停")
        model.turnStarted()
        #expect(model.canStop)
        async let first: Void = model.stop()
        async let second: Void = model.stop()
        _ = await (first, second)
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
        #expect(model.settings?.effectiveReasoningEffort == "max")
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
        #expect(await relay.calls == [.run("go on", compact: false)])
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

    @Test("面板还没载入：发送照常，不带档位（执行端按默认档跑）")
    func permissionModeUnknown() async throws {
        let relay = FakeComposerRelay()
        let model = composer(relay: relay)
        model.edit(text: "go on", cursor: 5)
        await model.send()
        #expect(await relay.runPermissionModes == [""])
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
        #expect(model.settings?.reasoningEffort == "")
        #expect(model.settings?.effectiveReasoningEffort == "high")
        #expect(model.failure == .change)
    }

    @Test("思考档位：会话行为空时有效档位取后端配置，都空时是默认")
    func effectiveEffort() {
        var settings = sampleSettings
        #expect(settings.effectiveReasoningEffort == "high")
        settings.backendReasoningEffort = ""
        #expect(settings.effectiveReasoningEffort == "")
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
