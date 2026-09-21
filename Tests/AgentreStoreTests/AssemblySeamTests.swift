@testable import AgentreStore
import AgentreDomain
import AgentreWire
import Foundation
import Testing

/// 装配层要的几处本地库接缝（真实数据库、临时目录）：承载机查找、游标回退时丢掉旧编号的帧、
/// 领域写入端口（ConversationSaving / StartedConversationRecording）的遵从。
@Suite("本地库的装配接缝")
struct AssemblySeamTests {
    @Test("会话键记发起端，承载机另记：他端发起的会话经保存它的那台机器走")
    func carrierIsTheSavingMachine() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        let saved = try await store.save(summary("conv-1", peer: "origin-fp"), via: "carrier-fp")
        #expect(saved == ConversationKey(machineFingerprint: "origin-fp", conversationID: "conv-1"))
        #expect(try await store.carrier(of: saved) == "carrier-fp")
        #expect(try await openStore(directory).carrier(of: saved) == "carrier-fp")
        #expect(try await store.carrier(of: ConversationKey(machineFingerprint: "origin-fp", conversationID: "missing")) == nil)
    }

    @Test("机器的最高帧号低于本机游标：旧编号的帧整段丢掉、游标归零，已读位与摘要留着；重拉的帧不再被当重复丢掉")
    func rewindDropsStaleFrames() async throws {
        let directory = try TemporaryDirectory()
        let key = ConversationKey(machineFingerprint: "m", conversationID: "conv-1")
        do {
            let store = try openStore(directory)
            try await store.save(summary("conv-1", title: "Old", lastMessageAt: 4_000), via: "m")
            try await store.record((1...5).map { pulled("conv-1", seq: $0, createtime: 100, text: "old \($0)") }, via: "m")
            try await store.markRead(key)

            // 机器的帧号没倒退：什么都不动。
            #expect(try await store.rewind(key, highWater: 5) == false)
            #expect(try await store.transcript(key).count == 5)

            #expect(try await store.rewind(key, highWater: 3) == true)
            #expect(try await store.transcript(key).isEmpty)
            #expect(try await store.latestSeq(key) == 0)
            let row = try #require(try await store.conversation(key))
            #expect(row.readMarker == 4_000)
            #expect(row.title == "Old")

            try await store.record((1...3).map { pulled("conv-1", seq: $0, createtime: 200, text: "new \($0)") }, via: "m")
        }
        let reopened = try openStore(directory)
        let frames = try await reopened.transcript(key)
        #expect(try frames.map { try decode($0).runtimeEvent.textDelta.text } == ["new 1", "new 2", "new 3"])
        #expect(try await reopened.latestSeq(key) == 3)
        #expect(try await reopened.conversation(key)?.readMarker == 4_000)
    }

    @Test("ConversationSaving：机器清单里的一条收进库，拉回的帧照录源端时刻、按承载机落进那一条")
    func savingPort() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        let saving: any ConversationSaving = store
        let session = MachineSession(
            conversationID: "conv-1", peerFingerprint: "origin", title: "Fix", agentSyncID: "agent-1", cwd: "/w",
            projectSyncID: "p-1", backendType: "codex", lifecycleState: "running", waitingForInput: true,
            latestSeq: 9, lastMessageAt: 7_000
        )
        let key = try await saving.save(session, via: "carrier")
        #expect(key == ConversationKey(machineFingerprint: "origin", conversationID: "conv-1"))
        let row = try #require(try await store.conversation(key))
        #expect(row.peerFingerprint == "origin")
        #expect(row.title == "Fix")
        #expect(row.agentSyncID == "agent-1")
        #expect(row.cwd == "/w")
        #expect(row.projectSyncID == "p-1")
        #expect(row.backendType == "codex")
        #expect(row.lifecycleState == "running")
        #expect(row.waitingForInput)
        #expect(row.lastMessageAt == 7_000)
        #expect(row.latestSeq == 0)
        #expect(try await store.carrier(of: key) == "carrier")

        let frames = try (1...2).map { seq in
            PulledFrame(seq: Int64(seq), createtime: 0, payload: try event("conv-1", seq: 0, text: "t\(seq)").serializedData())
        }
        try await saving.record(frames, into: key, via: "carrier")
        let stored = try await store.transcript(key)
        #expect(stored.map(\.seq) == [1, 2])
        // 拉回的帧不是实时帧：0 照录为 0，不盖本机钟。
        #expect(stored.map(\.createtime) == [0, 0])
        // 历史帧不跟随摘要：等你处理仍由清单说了算。
        #expect(try await store.conversation(key)?.waitingForInput == true)
    }

    @Test("同一台承载机上两条同号会话（它自己的与它代转的他端的）：拉回的帧按会话键落进对的那一条")
    func savingPortKeepsSameIDConversationsApart() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        let own = try await store.save(summary("sess-1"), via: "carrier")
        let relayed = try await store.save(summary("sess-1", peer: "origin"), via: "carrier")

        let frames = try (1...2).map { seq in
            PulledFrame(seq: Int64(seq), createtime: 5, payload: try event("sess-1", seq: 0, text: "origin \(seq)").serializedData())
        }
        try await store.record(frames, into: relayed, via: "carrier")
        #expect(try await store.transcript(relayed).map(\.seq) == [1, 2])
        #expect(try await store.transcript(own).isEmpty)
        #expect(try await store.latestSeq(own) == 0)
    }

    @Test("StartedConversationRecording：手机新建的对话以承载机为键落库，处于运行中")
    func startedRecording() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        let recorder: any StartedConversationRecording = store
        let request = DispatchRequest(
            conversationID: "new-1", title: "Hello", userText: "Hello there", agentSyncID: "agent-1", projectSyncID: "p-1",
            target: DispatchChoice(deviceFingerprint: "m-1", deviceName: "mac", backendType: "claudecode", cwd: "/repo")
        )
        let key = try await recorder.record(StartedConversation(request: request))
        #expect(key == ConversationKey(machineFingerprint: "m-1", conversationID: "new-1"))
        let row = try #require(try await openStore(directory).conversation(key))
        #expect(row.title == "Hello")
        #expect(row.agentSyncID == "agent-1")
        #expect(row.projectSyncID == "p-1")
        #expect(row.cwd == "/repo")
        #expect(row.backendType == "claudecode")
        #expect(row.lifecycleState == SavedConversation.Lifecycle.running)
        #expect(try await store.carrier(of: key) == "m-1")
        // 刚从手机发出的一条：排在列表最前（最后活动是此刻），也不是未读——话是本机自己说的。
        #expect(row.lastMessageAt == fixedNow)
        #expect(!row.isUnread)
    }

    @Test("回合事件：开始、正常收场与出错收场分得开，插话取走带着执行端的句柄；别的帧不算")
    func turnSignals() throws {
        var started = Agentre_Wire_RpcNotification()
        started.turnStarted = Agentre_Wire_TurnStartedNotification()
        #expect(TurnSignal(payload: try started.serializedData()) == .started)

        var done = Agentre_Wire_RpcNotification()
        done.runResultDone = Agentre_Wire_RunResultDoneNotification()
        #expect(TurnSignal(payload: try done.serializedData()) == .ended(normally: true))
        done.runResultDone.stopErrorMessage = "boom"
        #expect(TurnSignal(payload: try done.serializedData()) == .ended(normally: false))

        var steer = Agentre_Wire_ConsumedSteer()
        steer.queuedID = "q-1"
        steer.text = "also lint"
        var consumed = Agentre_Wire_SteerConsumed()
        consumed.steers = [steer]
        var runtime = Agentre_Wire_RuntimeEventNotification()
        runtime.steerConsumed = consumed
        var notification = Agentre_Wire_RpcNotification()
        notification.runtimeEvent = runtime
        #expect(TurnSignal(payload: try notification.serializedData()) == .steersConsumed([ComposerConsumedSteer(queuedID: "q-1", text: "also lint")]))

        #expect(TurnSignal(payload: try event("c", seq: 1).serializedData()) == nil)
        #expect(TurnSignal(payload: Data([0xFF])) == nil)
    }
}
