@testable import AgentreStore
import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import Testing

private let machine = "machine-1"
private func key(_ id: String, machine: String = machine) -> ConversationKey {
    ConversationKey(machineFingerprint: machine, conversationID: id)
}

@Suite("本地会话库（真实数据库、临时目录）")
struct ConversationStoreTests {
    @Test("保存一条会话后摘要与帧落盘；冷启动、没有任何网络也读出同一份内容")
    func savedConversationSurvivesColdStart() async throws {
        let directory = try TemporaryDirectory()
        var before: (SavedConversation?, [TranscriptFrame])
        do {
            let store = try openStore(directory)
            let saved = try await store.save(summary("conv-1", title: "修一个 bug", lastMessageAt: 1_700), via: machine)
            #expect(saved == key("conv-1"))
            try await store.record([pulled("conv-1", seq: 1, createtime: 1_000), pulled("conv-1", seq: 2, createtime: 0)], via: machine)
            try await store.record([live("conv-1", seq: 3)], via: machine)
            before = (try await store.conversation(saved), try await store.transcript(saved))
        }

        #expect(FileManager.default.fileExists(atPath: directory.url.appending(path: LocalConversationStore.fileName).path()))

        // 冷启动：前一个实例已放掉，新实例只有这个目录；此处不存在任何中继。
        let reopened = try openStore(directory)
        let conversation = try #require(try await reopened.conversation(key("conv-1")))
        #expect(conversation == before.0)
        #expect(conversation.title == "修一个 bug")
        #expect(conversation.agentSyncID == "agent-conv-1")
        #expect(conversation.cwd == "/work/conv-1")
        #expect(conversation.backendType == "claudecode")
        #expect(conversation.waitingForInput)
        #expect(conversation.lastMessageAt == 1_700)
        // 游标是本机自己的：落了几帧就是几，不是机器报的高水位。
        #expect(conversation.latestSeq == 3)
        #expect(try await reopened.conversations() == [conversation])

        let frames = try await reopened.transcript(key("conv-1"))
        #expect(frames == before.1)
        #expect(frames.map(\.seq) == [1, 2, 3])
        // 发生时刻原样取自载体：拉回的照录（0 仍是 0，不编一个），实时的盖收帧那一刻。
        #expect(frames.map(\.createtime) == [1_000, 0, fixedNow])
        // 落的是带号的 wire 通知：帧号盖进了载荷。
        #expect(try frames.map { try decode($0).runtimeEvent.seq } == [1, 2, 3])
        #expect(try decode(frames[0]).runtimeEvent.textDelta.text == "frame 1")
    }

    @Test("同一 seq 到两次只落一行，先到的那一行为准——一批之内、两批之间、跨冷启动都一样")
    func duplicateSeqLandsOnce() async throws {
        let directory = try TemporaryDirectory()
        do {
            let store = try openStore(directory)
            try await store.save(summary("conv-1"), via: machine)
            try await store.record([
                pulled("conv-1", seq: 1, createtime: 10, text: "first"),
                pulled("conv-1", seq: 1, createtime: 11, text: "same batch"),
            ], via: machine)
            try await store.record([live("conv-1", seq: 1, text: "live again")], via: machine)
        }
        let reopened = try openStore(directory)
        try await reopened.record([pulled("conv-1", seq: 1, createtime: 12, text: "after cold start")], via: machine)

        let frames = try await reopened.transcript(key("conv-1"))
        try #require(frames.count == 1)
        #expect(try decode(frames[0]).runtimeEvent.textDelta.text == "first")
        #expect(frames[0].createtime == 10)
        #expect(try await reopened.rowCounts().frames == 1)
    }

    @Test("补齐从本机已有的最大 seq 起：冷启动后 attach 的 pull 游标是 7，不是 0")
    func catchUpResumesFromStoredSeq() async throws {
        let directory = try TemporaryDirectory()
        do {
            let store = try openStore(directory)
            try await store.save(summary("conv-1"), via: machine)
            // 有洞也按最大号算：对端回收过前缀时首帧不是 1。
            try await store.record((3...7).map { pulled("conv-1", seq: $0, createtime: $0) }, via: machine)
        }
        let store = try openStore(directory)
        let cursor = try await store.latestSeq(key("conv-1"))
        #expect(cursor == 7)
        #expect(try await store.latestSeq(key("never-saved")) == 0)

        let (connection, channel, socket, id) = try await readyChannel(.machine(fingerprint: machine))
        let following = Task { try await store.follow(channel.notifications.map(IncomingFrame.init), via: machine) }
        defer { following.cancel() }

        async let attached = channel.attach(conversationID: "conv-1", after: cursor)
        let attach = try await socket.nextRequest(on: id, method: .sessionAttach)
        var attachResponse = Agentre_Wire_SessionAttachResponse()
        attachResponse.latestSeq = 9
        socket.respond(id, to: attach, with: attachResponse)
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        #expect(try Agentre_Wire_SessionPullRequest(serializedBytes: pull.request.encodedPayload).cursor == 7)
        var page = Agentre_Wire_SessionPullResponse()
        page.notifications = [durable("conv-1", seq: 8, createtime: 8), durable("conv-1", seq: 9, createtime: 9)]
        page.cursor = 9
        socket.respond(id, to: pull, with: page)
        _ = try await attached

        let seqs = try await eventually("frames 8 and 9 stored") {
            let seqs = try await store.transcript(key("conv-1")).map(\.seq)
            return seqs.last == 9 ? seqs : nil
        }
        #expect(seqs == [3, 4, 5, 6, 7, 8, 9])
        #expect(try await store.latestSeq(key("conv-1")) == 9)
        await connection.stop()
    }

    @Test("attach 之后的实时帧与 pull 回来的历史帧经同一条路径落库")
    func liveAndPulledShareOnePath() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1"), via: machine)

        let (connection, channel, socket, id) = try await readyChannel(.machine(fingerprint: machine))
        let following = Task { try await store.follow(channel.notifications.map(IncomingFrame.init), via: machine) }
        defer { following.cancel() }

        async let attached = channel.attach(conversationID: "conv-1", after: try await store.latestSeq(key("conv-1")))
        let attach = try await socket.nextRequest(on: id, method: .sessionAttach)
        socket.respond(id, to: attach, with: Agentre_Wire_SessionAttachResponse())
        let pull = try await socket.nextRequest(on: id, method: .sessionPull)
        var page = Agentre_Wire_SessionPullResponse()
        page.notifications = [durable("conv-1", seq: 1, createtime: 100), durable("conv-1", seq: 2, createtime: 200)]
        page.cursor = 2
        socket.respond(id, to: pull, with: page)
        _ = try await attached

        // attach 之后机器推来的实时帧；中间夹一帧预览帧（不带号，丢了就丢了）
        // 与一帧不属于任何已保存会话的帧（一个字都不落）。
        socket.notify(id, event("conv-1", seq: 0, text: "typing…", preview: true))
        socket.notify(id, event("conv-unsaved", seq: 1))
        socket.notify(id, event("conv-1", seq: 3, text: "live"))

        let frames = try await eventually("live frame 3 stored") {
            let frames = try await store.transcript(key("conv-1"))
            return frames.last?.seq == 3 ? frames : nil
        }
        #expect(frames.map(\.seq) == [1, 2, 3])
        #expect(frames.map(\.createtime) == [100, 200, fixedNow])
        #expect(try decode(frames[2]).runtimeEvent.textDelta.text == "live")
        #expect(try await store.conversations().map(\.key) == [key("conv-1")])
        #expect(try await store.rowCounts().frames == 3)
        await connection.stop()
    }

    @Test("未保存的会话一帧都不落；预览帧与不带号的帧不进转录")
    func onlySavedDurableFramesLand() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1"), via: machine)
        try await store.record([
            live("conv-other", seq: 1),
            IncomingFrame(conversationID: "conv-1", seq: nil, createtime: nil, payload: event("conv-1", seq: 0, preview: true)),
            IncomingFrame(conversationID: "conv-1", seq: 4, createtime: nil, payload: event("conv-1", seq: 4, preview: true)),
            IncomingFrame(conversationID: nil, seq: nil, createtime: nil, payload: Agentre_Wire_RpcNotification()),
        ], via: machine)
        // 同一会话 ID 经另一台机器到达：那是另一条会话。
        try await store.record([live("conv-1", seq: 1)], via: "machine-2")
        #expect(try await store.rowCounts().frames == 0)
        #expect(try await store.latestSeq(key("conv-1")) == 0)
    }

    @Test("已读位随会话记录并在冷启动后仍生效；从未读过的一律未读")
    func readMarkerSurvivesColdStart() async throws {
        let directory = try TemporaryDirectory()
        do {
            let store = try openStore(directory)
            try await store.save(summary("conv-read", lastMessageAt: 5_000), via: machine)
            try await store.save(summary("conv-never", lastMessageAt: 1_000), via: machine)
            #expect(try await store.conversation(key("conv-read"))?.isUnread == true)
            try await store.markRead(key("conv-read"))
        }
        let store = try openStore(directory)
        let read = try #require(try await store.conversation(key("conv-read")))
        #expect(read.readMarker == 5_000)
        #expect(!read.isUnread)
        let never = try #require(try await store.conversation(key("conv-never")))
        #expect(never.readMarker == nil)
        #expect(never.isUnread)
        // 列表新的在前。
        #expect(try await store.conversations().map(\.key.conversationID) == ["conv-read", "conv-never"])

        // 机器报来更晚的活动：再保存（刷新摘要）不抹掉已读位，而那条又成了未读。
        try await store.save(summary("conv-read", title: "renamed", lastMessageAt: 6_000), via: machine)
        let refreshed = try #require(try await store.conversation(key("conv-read")))
        #expect(refreshed.title == "renamed")
        #expect(refreshed.readMarker == 5_000)
        #expect(refreshed.isUnread)
    }

    @Test("删除一条会话当场没了，此后到达的帧也不再写回；其余会话不受影响")
    func deleteLeavesNoRows() async throws {
        let directory = try TemporaryDirectory()
        do {
            let store = try openStore(directory)
            try await store.save(summary("conv-gone"), via: machine)
            try await store.save(summary("conv-kept"), via: machine)
            try await store.record([live("conv-gone", seq: 1), live("conv-gone", seq: 2), live("conv-kept", seq: 1)], via: machine)
            try await store.markRead(key("conv-gone"))
            try await store.delete(key("conv-gone"))
            try await store.record([live("conv-gone", seq: 3)], via: machine)
        }
        let store = try openStore(directory)
        #expect(try await store.conversation(key("conv-gone")) == nil)
        #expect(try await store.transcript(key("conv-gone")).isEmpty)
        #expect(try await store.latestSeq(key("conv-gone")) == 0)
        #expect(try await store.conversations().map(\.key) == [key("conv-kept")])
        #expect(try await store.rowCounts().frames == 1)

        // 重新保存是一条新的记录：没有旧的已读位与游标。
        try await store.save(summary("conv-gone"), via: machine)
        let again = try #require(try await store.conversation(key("conv-gone")))
        #expect(again.readMarker == nil)
        #expect(again.latestSeq == 0)
    }

    @Test("退出登录清空整个库：冷启动后一行会话、一行帧都不剩")
    func signOutLeavesNoRows() async throws {
        let directory = try TemporaryDirectory()
        do {
            let store = try openStore(directory)
            for id in ["conv-1", "conv-2"] {
                try await store.save(summary(id, lastMessageAt: 10), via: machine)
                try await store.record((1...5).map { live(id, seq: $0) }, via: machine)
                try await store.markRead(key(id))
            }
            try await store.removeAll()
        }
        let store = try openStore(directory)
        #expect(try await store.conversations().isEmpty)
        let counts = try await store.rowCounts()
        #expect(counts.conversations == 0)
        #expect(counts.frames == 0)
    }

    @Test("退出登录时删行失败：库文件整个删掉重开——本实例与冷启动都读不到上一个账号的行，库照常可用")
    func removeAllFallsBackToAFreshStore() async throws {
        struct ClearFailed: Error {}
        let directory = try TemporaryDirectory()
        do {
            let store = try LocalConversationStore(directory: directory.url, now: { fixedNow }, clearRows: { _ in throw ClearFailed() })
            for id in ["conv-1", "conv-2"] {
                try await store.save(summary(id, lastMessageAt: 10), via: machine)
                try await store.record((1...5).map { live(id, seq: $0) }, via: machine)
                try await store.markRead(key(id))
            }
            await #expect(throws: Never.self) { try await store.removeAll() }
            #expect(try await store.conversations().isEmpty)
            #expect(try await store.conversation(key("conv-1")) == nil)
            #expect(try await store.transcript(key("conv-1")).isEmpty)
            #expect(try await store.latestSeq(key("conv-2")) == 0)

            // 重开的是一个能用的库：下一个账号保存的会话照常落盘。
            try await store.save(summary("conv-3", lastMessageAt: 20), via: machine)
            try await store.record([live("conv-3", seq: 1)], via: machine)
            #expect(try await store.conversations().map(\.key.conversationID) == ["conv-3"])
        }
        let reopened = try openStore(directory)
        #expect(try await reopened.conversations().map(\.key.conversationID) == ["conv-3"])
        let counts = try await reopened.rowCounts()
        #expect(counts.conversations == 1)
        #expect(counts.frames == 1)
    }

    @Test("批量追加带去重在 SwiftData 上的代价（决策 18 的逃生口判据）")
    func bulkAppendCost() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1"), via: machine)
        let clock = ContinuousClock()

        // 一轮离线两天的补齐：十页、每页 200 帧，逐页落库。
        let pages = (0..<10).map { page in (1...200).map { pulled("conv-1", seq: Int64(page * 200 + $0), createtime: 1) } }
        let fresh = try await clock.measure { for page in pages { try await store.record(page, via: machine) } }
        // 同一段再到一遍（重连后重叠的一页）：全是重复。
        let replay = try await clock.measure { for page in pages { try await store.record(page, via: machine) } }
        // 实时帧逐帧落库。
        let liveFrames = (2001...2200).map { live("conv-1", seq: Int64($0)) }
        let oneByOne = try await clock.measure { for frame in liveFrames { try await store.record([frame], via: machine) } }

        print("bulk append: 2000 fresh in \(fresh), 2000 duplicates in \(replay), 200 live one-by-one in \(oneByOne)")
        #expect(try await store.rowCounts().frames == 2200)
        #expect(try await store.latestSeq(key("conv-1")) == 2200)
        #expect(fresh < .seconds(2))
        #expect(replay < .seconds(2))
        #expect(oneByOne < .seconds(2))
    }
}
