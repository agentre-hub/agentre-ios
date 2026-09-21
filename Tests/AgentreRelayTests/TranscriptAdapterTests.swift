import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

private func event(_ seq: Int64, preview: Bool = false, _ fill: (inout Agentre_Wire_RuntimeEventNotification) -> Void) -> Agentre_Wire_RpcNotification {
    var runtime = Agentre_Wire_RuntimeEventNotification()
    runtime.conversationID = "conv-1"
    runtime.seq = seq
    runtime.preview = preview
    fill(&runtime)
    var notification = Agentre_Wire_RpcNotification()
    notification.runtimeEvent = runtime
    return notification
}

private func text(_ seq: Int64, _ value: String, preview: Bool = false) -> Agentre_Wire_RpcNotification {
    event(seq, preview: preview) {
        var delta = Agentre_Wire_TextDelta()
        delta.text = value
        $0.textDelta = delta
    }
}

private let key = ConversationKey(machineFingerprint: "origin-fp", conversationID: "conv-1")

@Suite struct TranscriptRelayAdapterTests {
    @Test("补拉：经承载机的 machine: 通道发 sessionPull（conversation_id / 发起端 / 游标 / 条数），页逐格映射")
    func pullsPage() async throws {
        let harness = await Harness.started()
        let adapter = RelayTranscript(connection: harness.connection, carrier: { _ in "carrier-fp" })
        async let page = adapter.pull(key, peerFingerprint: "peer-1", cursor: 10, limit: 50)
        let (socket, id) = try await harness.machineChannel("carrier-fp")
        let request = try await socket.nextRequest(on: id, method: .sessionPull)
        let body = try request.body(Agentre_Wire_SessionPullRequest.self)
        #expect(body.conversationID == "conv-1")
        #expect(body.peerFingerprint == "peer-1")
        #expect(body.cursor == 10)
        #expect(body.limit == 50)

        var response = Agentre_Wire_SessionPullResponse()
        var frame = Agentre_Wire_DurableNotification()
        frame.seq = 11
        frame.payload = text(11, "hi")
        frame.createtime = 5_000
        response.notifications = [frame]
        response.cursor = 11
        response.hasMore_p = true
        response.oldestSeq = 3
        socket.respond(id, to: request, with: response)

        let result = try await page
        #expect(result.cursor == 11)
        #expect(result.hasMore)
        #expect(result.oldestSeq == 3)
        #expect(result.frames == [TranscriptFrame(seq: 11, createtime: 5_000, payload: try text(11, "hi").serializedData())])
    }

    @Test("默认通道就是会话键上的机器指纹")
    func defaultCarrierIsKeyMachine() async throws {
        let harness = await Harness.started()
        let adapter = RelayTranscript(connection: harness.connection)
        async let page = adapter.pull(key, peerFingerprint: "", cursor: 0, limit: 5)
        let (socket, id) = try await harness.machineChannel("origin-fp")
        let request = try await socket.nextRequest(on: id, method: .sessionPull)
        socket.respond(id, to: request, with: Agentre_Wire_SessionPullResponse())
        #expect(try await page.frames.isEmpty)
    }

    @Test("接上实时帧：从本机游标起 attach 并补齐；补齐帧带 createtime，实时帧与预览帧不带（任务 4 的实时判据）")
    func attachStreamsLiveFrames() async throws {
        let harness = await Harness.started()
        let adapter = RelayTranscript(
            connection: harness.connection, carrier: { _ in "carrier-fp" }, localCursor: { $0 == key ? 4 : 0 }
        )
        let attaching = Task { try await adapter.attach(key, peerFingerprint: "peer-1") }
        let (socket, id) = try await harness.machineChannel("carrier-fp")
        let attach = try await socket.nextRequest(on: id, method: .sessionAttach)
        let attachBody = try attach.body(Agentre_Wire_SessionAttachRequest.self)
        #expect(attachBody.conversationID == "conv-1")
        #expect(attachBody.peerFingerprint == "peer-1")
        var attached = Agentre_Wire_SessionAttachResponse()
        attached.latestSeq = 5
        socket.respond(id, to: attach, with: attached)

        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        #expect(try pull.body(Agentre_Wire_SessionPullRequest.self).cursor == 4)
        var page = Agentre_Wire_SessionPullResponse()
        var frame = Agentre_Wire_DurableNotification()
        frame.seq = 5
        frame.payload = text(5, "caught up")
        frame.createtime = 9_000
        page.notifications = [frame]
        page.cursor = 5
        socket.respond(id, to: pull, with: page)

        let live = Collected(try await attaching.value)
        socket.notify(id, text(0, "typing…", preview: true))
        socket.notify(id, text(6, "live"))
        // 另一条对话的帧不进这条流。
        var other = text(7, "elsewhere")
        other.runtimeEvent.conversationID = "conv-2"
        socket.notify(id, other)

        _ = try await eventually("live seq 6") { live.items.contains { $0.seq == 6 } ? true : nil }
        #expect(live.items == [
            LiveTranscriptFrame(seq: 5, createtime: 9_000, payload: try text(5, "caught up").serializedData()),
            LiveTranscriptFrame(seq: nil, createtime: 0, payload: try text(0, "typing…", preview: true).serializedData()),
            LiveTranscriptFrame(seq: 6, createtime: 0, payload: try text(6, "live").serializedData()),
        ])
    }

    @Test("服务端关掉这条机器通道：实时流随之结束，不留一个永远等不到帧的界面")
    func streamEndsWhenChannelCloses() async throws {
        let harness = await Harness.started()
        let adapter = RelayTranscript(connection: harness.connection)
        let attaching = Task { try await adapter.attach(key, peerFingerprint: "") }
        let (socket, id) = try await harness.machineChannel("origin-fp")
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .sessionAttach), with: Agentre_Wire_SessionAttachResponse())
        socket.respond(id, to: try await socket.nextRequest(on: id, method: .sessionPull), with: Agentre_Wire_SessionPullResponse())
        let live = Collected(try await attaching.value)
        socket.push(id, Data())
        _ = try await eventually("stream finished") { live.finished ? true : nil }
    }

    @Test("错误应答与到期无应答都以领域失败收场", arguments: FailureScenario.allCases)
    func failuresAreDomainFacts(_ scenario: FailureScenario) async throws {
        let pull = try await failure(scenario, method: .sessionPull, on: "origin-fp") { harness in
            try await RelayTranscript(connection: harness.connection).pull(key, peerFingerprint: "", cursor: 0, limit: 5)
        }
        #expect(pull as? RelayFailure == scenario.expected)
        let attach = try await failure(scenario, method: .sessionAttach, on: "origin-fp") { harness in
            _ = try await RelayTranscript(connection: harness.connection).attach(key, peerFingerprint: "")
        }
        #expect(attach as? RelayFailure == scenario.expected)
    }
}

@Suite struct WireTranscriptDecoderTests {
    private let decoder = WireTranscriptDecoder()

    private func decode(_ notification: Agentre_Wire_RpcNotification) throws -> DecodedNotification? {
        decoder.decode(try notification.serializedData())
    }

    @Test("正文、思考、用户消息与预览标志")
    func textualEvents() throws {
        #expect(try decode(text(3, "hello")) == DecodedNotification(event: .textDelta("hello")))
        #expect(try decode(text(0, "par", preview: true)) == DecodedNotification(preview: true, event: .textDelta("par")))
        #expect(try decode(event(4) {
            var thinking = Agentre_Wire_ThinkingDelta()
            thinking.text = "hmm"
            $0.thinkingDelta = thinking
        }) == DecodedNotification(event: .thinkingDelta("hmm")))
        #expect(try decode(event(5) {
            var user = Agentre_Wire_UserMessage()
            user.text = "please fix"
            $0.userMessage = user
        }) == DecodedNotification(event: .userMessage("please fix")))
        #expect(try decode(event(6) {
            var steer = Agentre_Wire_SteerConsumed()
            steer.steers = [Agentre_Wire_ConsumedSteer.with { $0.text = "a" }, Agentre_Wire_ConsumedSteer.with { $0.text = "b" }]
            $0.steerConsumed = steer
        }) == DecodedNotification(event: .steerConsumed(["a", "b"])))
    }

    @Test("工具调用解出入参与规范形态，结果带错误标志与父调用")
    func toolEvents() throws {
        let call = try decode(event(7) {
            var tool = Agentre_Wire_ToolCall()
            tool.id = "t1"
            tool.name = "Bash"
            tool.input = Data(#"{"command":"ls"}"#.utf8)
            tool.canonical = Data(#"{"kind":"file.write","lines":3}"#.utf8)
            tool.parentToolCallID = "p1"
            $0.toolCall = tool
        })
        #expect(call == DecodedNotification(event: .toolCall(ToolUse(
            id: "t1", name: "Bash", input: ["command": .string("ls")],
            canonical: Canonical(kind: "file.write", fields: ["lines": .number(3)]), parentID: "p1"
        ))))
        let bare = try decode(event(8) {
            var tool = Agentre_Wire_ToolCall()
            tool.id = "t2"
            tool.name = "Read"
            $0.toolCall = tool
        })
        #expect(bare == DecodedNotification(event: .toolCall(ToolUse(id: "t2", name: "Read"))))
        let result = try decode(event(9) {
            var tool = Agentre_Wire_ToolResult()
            tool.toolCallID = "t1"
            tool.content = "boom"
            tool.isError = true
            $0.toolResult = tool
        })
        #expect(result == DecodedNotification(event: .toolResult(ToolResult(toolCallID: "t1", text: "boom", isError: true))))
    }

    @Test("审批与提问：请求带入参与每一问的选项，决议只带请求号")
    func approvalEvents() throws {
        let permission = try decode(event(10) {
            var request = Agentre_Wire_ToolPermissionRequest()
            request.requestID = "r1"
            request.toolCallID = "t1"
            request.toolName = "Bash"
            request.input = Data(#"{"command":"rm -rf build"}"#.utf8)
            $0.toolPermissionRequest = request
        })
        #expect(permission == DecodedNotification(event: .permissionRequest(PermissionRequest(
            requestID: "r1", toolCallID: "t1", toolName: "Bash", input: ["command": .string("rm -rf build")]
        ))))
        #expect(try decode(event(11) {
            var resolved = Agentre_Wire_ToolPermissionResolved()
            resolved.requestID = "r1"
            resolved.allowed = true
            $0.toolPermissionResolved = resolved
        }) == DecodedNotification(event: .permissionResolved(requestID: "r1", allowed: true)))

        let question = try decode(event(12) {
            var ask = Agentre_Wire_UserAskRequest()
            ask.requestID = "q1"
            ask.toolCallID = "t9"
            var first = Agentre_Wire_AskQuestion()
            first.id = "q-a"
            first.question = "Which database?"
            first.header = "DB"
            first.multiSelect = true
            first.options = [
                Agentre_Wire_AskOption.with { $0.label = "Postgres"; $0.description_p = "relational" },
                Agentre_Wire_AskOption.with { $0.label = "SQLite" },
            ]
            var second = Agentre_Wire_AskQuestion()
            second.question = "Token?"
            second.isSecret = true
            ask.questions = [first, second]
            $0.userAskRequest = ask
        })
        #expect(question == DecodedNotification(event: .questionRequest(QuestionRequest(
            requestID: "q1", toolCallID: "t9",
            questions: [
                AskQuestion(id: "q-a", question: "Which database?", header: "DB", multiSelect: true, options: [
                    AskOption(label: "Postgres", description: "relational"), AskOption(label: "SQLite"),
                ]),
                AskQuestion(question: "Token?", isSecret: true),
            ]
        ))))
        #expect(try decode(event(13) {
            var resolved = Agentre_Wire_UserAskResolved()
            resolved.requestID = "q1"
            $0.userAskResolved = resolved
        }) == DecodedNotification(event: .questionResolved(requestID: "q1")))
    }

    @Test("Subagent 三相、用量、上下文窗口、错误")
    func runtimeState() throws {
        let started = try decode(event(14) {
            var sub = Agentre_Wire_SubagentEvent()
            sub.toolCallID = "t3"
            sub.info = Agentre_Wire_SubagentInfo.with {
                $0.taskID = "task-1"; $0.subagentType = "explore"; $0.taskDescription = "look"
                $0.durationMs = 12; $0.toolUses = 3; $0.status = "running"
            }
            $0.subagentStarted = sub
        })
        #expect(started == DecodedNotification(event: .subagent(SubagentUpdate(toolCallID: "t3", phase: .started, info: SubagentState(
            taskID: "task-1", status: "running", subagentType: "explore", taskDescription: "look", durationMs: 12, toolUses: 3
        )))))
        let progress = try decode(event(15) { $0.subagentProgress = Agentre_Wire_SubagentEvent.with { $0.toolCallID = "t3" } })
        #expect(progress == DecodedNotification(event: .subagent(SubagentUpdate(toolCallID: "t3", phase: .progress, info: SubagentState()))))
        let done = try decode(event(16) { $0.subagentDone = Agentre_Wire_SubagentEvent.with { $0.toolCallID = "t3" } })
        #expect(done == DecodedNotification(event: .subagent(SubagentUpdate(toolCallID: "t3", phase: .done, info: SubagentState()))))

        #expect(try decode(event(17) {
            $0.usageUpdate = Agentre_Wire_UsageUpdate.with { $0.totalInputTokens = 1_200; $0.contextWindow = 200_000 }
        }) == DecodedNotification(event: .usage(totalInputTokens: 1_200, contextWindow: 200_000)))
        #expect(try decode(event(18) {
            $0.contextWindowUpdated = Agentre_Wire_ContextWindowUpdated.with { $0.tokens = 100_000 }
        }) == DecodedNotification(event: .contextWindow(100_000)))
        #expect(try decode(event(19) {
            $0.error = Agentre_Wire_ErrorEvent.with { $0.message = "model overloaded" }
        }) == DecodedNotification(event: .error("model overloaded")))
        #expect(try decode(event(20) {
            $0.done = Agentre_Wire_Done.with { $0.durationMs = 900 }
        }) == DecodedNotification(event: .turnDone(TurnDone(durationMs: 900))))
        #expect(try decode(event(21) { $0.runtimeStatus = Agentre_Wire_RuntimeStatus.with { $0.status = "compacting" } })
            == DecodedNotification(event: .ignored))
    }

    @Test("轮次边界：开始与终态（含自主轮）；自主轮里的事件与普通事件同解")
    func turnBoundaries() throws {
        var started = Agentre_Wire_RpcNotification()
        started.turnStarted = Agentre_Wire_TurnStartedNotification.with { $0.conversationID = "conv-1"; $0.seq = 1 }
        #expect(try decode(started) == DecodedNotification(event: .turnStarted))
        var autonomous = Agentre_Wire_RpcNotification()
        autonomous.autonomousTurnStarted = Agentre_Wire_AutonomousTurnStartedNotification.with { $0.conversationID = "conv-1" }
        #expect(try decode(autonomous) == DecodedNotification(event: .turnStarted))

        let result = Agentre_Wire_RunResultDoneNotification.with {
            $0.conversationID = "conv-1"; $0.durationMs = 3_000; $0.contextWindow = 200_000; $0.stopErrorMessage = "stopped"
        }
        var done = Agentre_Wire_RpcNotification()
        done.runResultDone = result
        #expect(try decode(done) == DecodedNotification(event: .turnDone(TurnDone(durationMs: 3_000, contextWindow: 200_000, stopError: "stopped"))))
        var autonomousDone = Agentre_Wire_RpcNotification()
        autonomousDone.autonomousTurnDone = result
        #expect(try decode(autonomousDone) == DecodedNotification(event: .turnDone(TurnDone(durationMs: 3_000, contextWindow: 200_000, stopError: "stopped"))))

        var autonomousEvent = Agentre_Wire_RpcNotification()
        autonomousEvent.autonomousTurnEvent = text(22, "auto").runtimeEvent
        #expect(try decode(autonomousEvent) == DecodedNotification(event: .textDelta("auto")))
    }

    @Test("不属于转录的通知与坏字节解不出")
    func notTranscript() throws {
        var terminal = Agentre_Wire_RpcNotification()
        terminal.terminalData = Agentre_Wire_TerminalDataNotification.with { $0.terminalID = "t" }
        #expect(try decode(terminal) == nil)
        #expect(try decode(Agentre_Wire_RpcNotification()) == nil)
        #expect(decoder.decode(Data([0xFF, 0xFF, 0xFF])) == nil)
    }
}
