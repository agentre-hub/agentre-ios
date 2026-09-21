import AgentreDomain
import AgentreStore
@testable import AgentreUI
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

/// 保存到手机：收进本地库 → attach → 从本机最大帧号起按游标 pull 到底。
@MainActor
@Suite("机器详情：保存到手机")
struct SaveToPhoneTests {
    @Test("保存：先收进库再 attach，按游标一批批拉到底，帧全部落库；这一行随即读作已保存")
    func savePullsTheWholeTranscript() async throws {
        let source = FakeSessionSource([session("a", title: "Fix build"), session("b")])
        let store = FakeSavingStore()
        let transfer = FakeTransfer(["a": frames(1...5)], batch: 2)
        let detail = MachineDetailModel(machine: onlineMachine(), sessions: source, store: store, transfer: transfer)
        await detail.load()
        #expect(detail.rows.map(\.isSaved) == [false, false])
        await detail.save("a")
        #expect(await transfer.attaches == ["a"])
        #expect(await transfer.pulls == [0, 2, 4])
        #expect(await store.transcript(key("a")).map(\.seq) == [1, 2, 3, 4, 5])
        #expect(await store.conversation(key("a"))?.title == "Fix build")
        #expect(detail.rows.map(\.isSaved) == [true, false])
        #expect(!detail.rows[0].isSaving)
    }

    @Test("补齐从本机已有的最大帧号起，不从头重放")
    func pullStartsAfterTheLocalCursor() async throws {
        let store = FakeSavingStore(saved: [key("a")])
        await store.record(frames(1...3), into: key("a"), via: machineFingerprint)
        let transfer = FakeTransfer(["a": frames(1...5)], batch: 10)
        try await ConversationSaver(store: store, transfer: transfer).save(session("a"), on: onlineMachine())
        #expect(await transfer.pulls == [3])
        #expect(await store.transcript(key("a")).map(\.seq) == [1, 2, 3, 4, 5])
    }

    @Test("半途拉取失败：这条从库里撤掉，行仍是未保存、带失败标记，可以重试")
    func failedPullRollsBack() async throws {
        let source = FakeSessionSource([session("a")])
        let store = FakeSavingStore()
        let transfer = FakeTransfer(["a": frames(1...5)], batch: 2)
        await transfer.configure(failPullAfterFirstBatch: true)
        let detail = MachineDetailModel(machine: onlineMachine(), sessions: source, store: store, transfer: transfer)
        await detail.load()
        await detail.save("a")
        #expect(await store.conversation(key("a")) == nil)
        #expect(await store.transcript(key("a")).isEmpty)
        #expect(detail.rows[0].isSaved == false)
        #expect(detail.rows[0].saveFailed)
        await transfer.configure()
        await detail.save("a")
        #expect(detail.rows[0].isSaved)
        #expect(!detail.rows[0].saveFailed)
        #expect(await store.transcript(key("a")).count == 5)
    }

    @Test("本来就在库里的会话再存一次时失败：不撤掉已有的摘要与帧")
    func failureKeepsAnAlreadySavedConversation() async throws {
        let store = FakeSavingStore(saved: [key("a")])
        await store.record(frames(1...2), into: key("a"), via: machineFingerprint)
        let transfer = FakeTransfer(["a": frames(1...5)])
        await transfer.configure(failAttach: true)
        await #expect(throws: (any Error).self) {
            try await ConversationSaver(store: store, transfer: transfer).save(session("a"), on: onlineMachine())
        }
        #expect(await store.conversation(key("a")) != nil)
        #expect(await store.transcript(key("a")).map(\.seq) == [1, 2])
    }

    @Test("attach 失败：库里不留这条")
    func failedAttachLeavesNothing() async throws {
        let store = FakeSavingStore()
        let transfer = FakeTransfer(["a": frames(1...2)])
        await transfer.configure(failAttach: true)
        await #expect(throws: (any Error).self) {
            try await ConversationSaver(store: store, transfer: transfer).save(session("a"), on: onlineMachine())
        }
        #expect(await store.conversations().isEmpty)
    }

    @Test("机器说还有、游标却不前进：判失败而不是死循环")
    func stalledPullFails() async throws {
        struct Stalled: MachineSessionTransfer {
            func attach(conversationID: String, peerFingerprint: String, on machine: String) async throws -> Int64 { 9 }
            func pull(conversationID: String, peerFingerprint: String, after cursor: Int64, on machine: String) async throws -> PulledFrames {
                PulledFrames(frames: [], cursor: cursor, hasMore: true)
            }
        }
        let store = FakeSavingStore()
        await #expect(throws: ConversationSaver.Failure.stalledPull) {
            try await ConversationSaver(store: store, transfer: Stalled()).save(session("a"), on: onlineMachine())
        }
        #expect(await store.conversations().isEmpty)
    }

    @Test("离线的机器：保存不发任何请求")
    func offlineSavesNothing() async throws {
        let transfer = FakeTransfer(["a": frames(1...2)])
        let store = FakeSavingStore()
        await #expect(throws: (any Error).self) {
            try await ConversationSaver(store: store, transfer: transfer).save(session("a"), on: offlineMachine())
        }
        #expect(await transfer.attaches.isEmpty)
        #expect(await store.conversations().isEmpty)
    }

    // MARK: 真实数据库

    @Test("真实本地库：保存后它出现在消息列表、转录已落库；机器随后离线，已保存的照常可读")
    func savedConversationLandsInTheRealStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AgentreMachineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = try LocalConversationStore(directory: directory)
        let store = LocalStoreWriter(local)
        let payloads = try (1...3).map { seq in
            PulledFrame(seq: Int64(seq), createtime: 500, payload: try textNotification("conv-1", "line \(seq)").serializedData())
        }
        let source = FakeSessionSource([session("conv-1", title: "Fix build", at: 7_000), session("conv-2")])
        let transfer = FakeTransfer(["conv-1": payloads], batch: 2)
        let detail = MachineDetailModel(machine: onlineMachine(), sessions: source, store: store, transfer: transfer)
        await detail.load()
        await detail.save("conv-1")
        #expect(detail.rows.map(\.isSaved) == [true, false])

        let messages = MessagesModel(store: local)
        await messages.load()
        #expect(messages.conversations.map(\.key) == [key("conv-1")])
        #expect(messages.conversations.first?.title == "Fix build")
        #expect(try await local.transcript(key("conv-1")).map(\.seq) == [1, 2, 3])

        // 机器离线：详情页什么都不列，已保存的会话仍在本地库里可读。
        let offline = MachineDetailModel(machine: offlineMachine(), sessions: source, store: store, transfer: transfer)
        await offline.load()
        #expect(offline.rows.isEmpty)
        #expect(offline.counts == nil)
        await messages.load()
        #expect(messages.conversations.map(\.key) == [key("conv-1")])
        #expect(try await local.transcript(key("conv-1")).count == 3)
    }
}

func textNotification(_ conversationID: String, _ value: String) -> Agentre_Wire_RpcNotification {
    var delta = Agentre_Wire_TextDelta()
    delta.text = value
    var event = Agentre_Wire_RuntimeEventNotification()
    event.conversationID = conversationID
    event.textDelta = delta
    var notification = Agentre_Wire_RpcNotification()
    notification.runtimeEvent = event
    return notification
}

/// 把领域的写入端口接到真实本地库上（装配层的那一份在任务 12；这里只为验证落库的形状）。
struct LocalStoreWriter: ConversationSaving {
    let store: LocalConversationStore

    init(_ store: LocalConversationStore) { self.store = store }

    func save(_ session: MachineSession, via machine: String) async throws -> ConversationKey {
        var summary = Agentre_Wire_SessionSummary()
        summary.conversationID = session.conversationID
        summary.peerFingerprint = session.peerFingerprint
        summary.title = session.title
        summary.lifecycleState = session.lifecycleState
        summary.waitingForInput = session.waitingForInput
        summary.lastMessageAt = session.lastMessageAt
        return try await store.save(summary, via: machine)
    }

    func record(_ frames: [PulledFrame], into key: ConversationKey, via machine: String) async throws {
        let incoming = try frames.map {
            IncomingFrame(
                conversationID: key.conversationID, seq: $0.seq, createtime: $0.createtime,
                payload: try Agentre_Wire_RpcNotification(serializedBytes: $0.payload)
            )
        }
        try await store.record(incoming, via: machine)
    }

    func conversations() async throws -> [SavedConversation] { try await store.conversations() }
    func conversation(_ key: ConversationKey) async throws -> SavedConversation? { try await store.conversation(key) }
    func transcript(_ key: ConversationKey) async throws -> [TranscriptFrame] { try await store.transcript(key) }
    func latestSeq(_ key: ConversationKey) async throws -> Int64 { try await store.latestSeq(key) }
    func markRead(_ key: ConversationKey) async throws { try await store.markRead(key) }
    func delete(_ key: ConversationKey) async throws { try await store.delete(key) }
    func removeAll() async throws { try await store.removeAll() }
    func changes() async -> AsyncStream<Void> { await store.changes() }
}
