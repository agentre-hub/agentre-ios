import AgentreDomain
import AgentreStore
import AgentreWire
import Foundation
import Testing

/// 列表不进对话就要读到的东西，全部取自本地库：待批准的命令 / 待回答的问题、最后一句话，
/// 以及库变动的通知。
@Suite("本地库给列表的预览（真实数据库、临时目录）")
struct StorePreviewTests {
    @Test("等你批准的具体命令不进对话即可读，冷启动、没有任何中继也读得到")
    func pendingCommandReadableOffline() async throws {
        let directory = try TemporaryDirectory()
        do {
            let store = try openStore(directory)
            try await store.save(summary("conv-1", lifecycle: "running"), via: machine)
            try await store.record([
                live(permissionRequest("conv-1", id: "p0", input: #"{"command":"ls"}"#), seq: 1),
                live(permissionResolved("conv-1", id: "p0"), seq: 2),
                live(permissionRequest("conv-1", id: "p1", input: #"{"command":"rm -rf build","description":"清理"}"#), seq: 3),
            ], via: machine)
        }
        let row = try #require(try await openStore(directory).conversation(key("conv-1")))
        #expect(row.waitingForInput)
        #expect(row.pending == .permission(tool: "Bash", detail: "rm -rf build"))
    }

    @Test("等你回答的问题不进对话即可读；没有命令的工具给出它要动的文件，什么都没有时只给工具名")
    func pendingQuestionAndOtherTools() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("q"), via: machine)
        try await store.record([live(askRequest("q", id: "q1", question: "用哪个分支？"), seq: 1, conversationID: "q")], via: machine)
        #expect(try await store.conversation(key("q"))?.pending == .question("用哪个分支？"))

        try await store.save(summary("edit"), via: machine)
        try await store.record([live(permissionRequest("edit", id: "e1", tool: "Edit", input: #"{"file_path":"/work/main.go"}"#), seq: 1, conversationID: "edit")], via: machine)
        #expect(try await store.conversation(key("edit"))?.pending == .permission(tool: "Edit", detail: "/work/main.go"))

        try await store.save(summary("web"), via: machine)
        try await store.record([live(permissionRequest("web", id: "w1", tool: "WebSearch", input: "not json"), seq: 1, conversationID: "web")], via: machine)
        #expect(try await store.conversation(key("web"))?.pending == .permission(tool: "WebSearch", detail: nil))
    }

    @Test("不在等你处理时没有待决可读：落定了的、快照说不等了的都不算")
    func noPendingWhenNotWaiting() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1", lifecycle: "running"), via: machine)
        try await store.record([live(permissionRequest("conv-1", id: "p1"), seq: 1)], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.pending != nil)
        try await store.record([live(permissionResolved("conv-1", id: "p1"), seq: 2)], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.pending == nil)

        try await store.record([live(permissionRequest("conv-1", id: "p2"), seq: 3)], via: machine)
        try await store.save(summary("conv-1", lifecycle: "idle", waiting: false), via: machine)
        #expect(try await store.conversations().first?.pending == nil)
    }

    @Test("最后一句话取自转录里最近一条正文或用户消息")
    func lastTextFromTranscript() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1"), via: machine)
        #expect(try await store.conversation(key("conv-1"))?.lastText == "")
        try await store.record([live(userMessage("conv-1", "帮我修一下构建"), seq: 1)], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.lastText == "帮我修一下构建")
        try await store.record([
            pulled(text("conv-1", "构建已修好"), seq: 2),
            pulled(permissionRequest("conv-1", id: "x"), seq: 3),
        ], via: machine)
        #expect(try await store.conversations().first?.lastText == "构建已修好")
    }

    @Test("库一变就通知订阅者：落帧、已读、删除都算")
    func changesAreAnnounced() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1"), via: machine)
        let changes = await store.changes()
        var iterator = changes.makeAsyncIterator()

        try await store.record([live(turnStarted("conv-1"))], via: machine)
        #expect(await iterator.next() != nil)
        try await store.markRead(key("conv-1"))
        #expect(await iterator.next() != nil)
        try await store.delete(key("conv-1"))
        #expect(await iterator.next() != nil)
        #expect(try await store.conversations().isEmpty)
    }
}
