import AgentreDomain
import AgentreStore
import AgentreWire
import Foundation
import Testing

/// 帧到达时本地库按服务端 mirror_svc 的 follow 规则更新那条会话的摘要
/// （agentre-server/internal/service/mirror_svc/mirror.go 的 follow / followTurn / followWaiter）。
@Suite("本地库跟随实时帧更新摘要（真实数据库、临时目录）")
struct StoreFollowTests {
    @Test("轮次开始推回 running 并把最后活动前移到此刻；结束推回 idle，带停止文案的是 failed，用户中断不算故障")
    func turnBoundariesDriveLifecycle() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1", lifecycle: "idle", lastMessageAt: 1_000), via: machine)

        try await store.record([live(turnStarted("conv-1"))], via: machine)
        var row = try #require(try await store.conversation(key("conv-1")))
        #expect(row.lifecycleState == "running")
        #expect(row.lastMessageAt == storeNow)

        try await store.record([live(runResultDone("conv-1"))], via: machine)
        row = try #require(try await store.conversation(key("conv-1")))
        #expect(row.lifecycleState == "idle")

        try await store.record([live(autonomousTurnStarted("conv-1"))], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.lifecycleState == "running")
        try await store.record([live(runResultDone("conv-1", stopError: "exit status 1", autonomous: true))], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.lifecycleState == "failed")

        try await store.record([live(turnStarted("conv-1")), live(runResultDone("conv-1", stopError: "aborted", code: -32013))], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.lifecycleState == "idle")
        // 边界帧线上不带号：只落摘要，不进转录。
        #expect(try await store.transcript(key("conv-1")).isEmpty)
    }

    @Test("最后活动只前移不倒退：对端报的时刻比本机钟新时不改写")
    func lastActivityOnlyMovesForward() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1", lastMessageAt: storeNow + 5_000), via: machine)
        try await store.record([live(turnStarted("conv-1"))], via: machine)
        let row = try #require(try await store.conversation(key("conv-1")))
        #expect(row.lifecycleState == "running")
        #expect(row.lastMessageAt == storeNow + 5_000)
    }

    @Test("等你处理按请求标识跟随：两次待决交错时落定一次仍在等，全部落定才不等")
    func waitingFollowsRequestIDs() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1", lifecycle: "running"), via: machine)

        try await store.record([live(permissionRequest("conv-1", id: "p1"), seq: 1)], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.waitingForInput == true)
        try await store.record([live(askRequest("conv-1", id: "q1", question: "用哪个分支？"), seq: 2)], via: machine)
        try await store.record([live(permissionResolved("conv-1", id: "p1"), seq: 3)], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.waitingForInput == true)
        try await store.record([live(askResolved("conv-1", id: "q1"), seq: 4)], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.waitingForInput == false)
        #expect(try await store.transcript(key("conv-1")).map(\.seq) == [1, 2, 3, 4])
    }

    @Test("轮次终态是等待的兜底出口：没有落定帧的收场也清掉等你处理")
    func turnEndClearsWaiting() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1", lifecycle: "running"), via: machine)
        try await store.record([live(permissionRequest("conv-1", id: "p1"), seq: 1)], via: machine)
        try await store.record([live(runResultDone("conv-1", stopError: "aborted", code: -32013))], via: machine)
        let row = try #require(try await store.conversation(key("conv-1")))
        #expect(!row.waitingForInput)
        #expect(row.lifecycleState == "idle")
    }

    @Test("快照是权威直到帧说过话：落定帧清掉快照带来的等待；新快照再次作废帧攒下的集合")
    func snapshotAuthorityUntilFramesSpeak() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1", lifecycle: "running", waiting: true), via: machine)
        // 与待决无关的帧不动这一列。
        try await store.record([live(text("conv-1", "在想"), seq: 1)], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.waitingForInput == true)
        // 落定一次我们没见过请求的待决：帧说过话了，此刻一个待决都没有。
        try await store.record([live(permissionResolved("conv-1", id: "old"), seq: 2)], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.waitingForInput == false)

        try await store.record([live(permissionRequest("conv-1", id: "p1"), seq: 3)], via: machine)
        // 机器的新快照说不等了：帧攒下的集合作废，这一列重新由快照说了算。
        try await store.save(summary("conv-1", lifecycle: "running", waiting: false), via: machine)
        #expect(try await store.conversation(key("conv-1"))?.waitingForInput == false)
        try await store.record([live(permissionRequest("conv-1", id: "p2"), seq: 4)], via: machine)
        try await store.record([live(permissionResolved("conv-1", id: "p2"), seq: 5)], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.waitingForInput == false)
    }

    @Test("补齐拉回的帧与重复投递不跟随：重放一条早已落定的请求不会把它算回「还等着」")
    func pulledAndDuplicateFramesDoNotFollow() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1", lifecycle: "idle", lastMessageAt: 1_000), via: machine)

        try await store.record([pulled(permissionRequest("conv-1", id: "p1"), seq: 1)], via: machine)
        var row = try #require(try await store.conversation(key("conv-1")))
        #expect(!row.waitingForInput)
        #expect(row.lastMessageAt == 1_000)
        #expect(row.latestSeq == 1)

        try await store.record([live(permissionRequest("conv-1", id: "p2"), seq: 2), live(permissionResolved("conv-1", id: "p2"), seq: 3)], via: machine)
        try await store.record([live(permissionRequest("conv-1", id: "p2"), seq: 2)], via: machine)
        row = try #require(try await store.conversation(key("conv-1")))
        #expect(!row.waitingForInput)
    }

    @Test("未保存的会话、经另一台机器到达的同号会话都不跟随")
    func unknownConversationsDoNotFollow() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1", lifecycle: "idle", lastMessageAt: 1_000), via: machine)
        try await store.record([live(turnStarted("conv-2"), conversationID: "conv-2")], via: machine)
        try await store.record([live(turnStarted("conv-1"))], via: "machine-2")
        let row = try #require(try await store.conversation(key("conv-1")))
        #expect(row.lifecycleState == "idle")
        #expect(row.lastMessageAt == 1_000)
        #expect(try await store.conversations().count == 1)
    }

    @Test("读过的会话在实时流量下重新变成未读：新一轮开始把最后活动推过已读位")
    func liveTurnMakesReadConversationUnread() async throws {
        let directory = try TemporaryDirectory()
        let store = try openStore(directory)
        try await store.save(summary("conv-1", lastMessageAt: 1_000), via: machine)
        try await store.markRead(key("conv-1"))
        #expect(try await store.conversation(key("conv-1"))?.isUnread == false)
        try await store.record([live(turnStarted("conv-1"))], via: machine)
        #expect(try await store.conversation(key("conv-1"))?.isUnread == true)
    }

    @Test("跟随改写的摘要落了盘：冷启动后照样读得到")
    func followedSummarySurvivesColdStart() async throws {
        let directory = try TemporaryDirectory()
        do {
            let store = try openStore(directory)
            try await store.save(summary("conv-1", lifecycle: "idle"), via: machine)
            try await store.record([live(turnStarted("conv-1")), live(permissionRequest("conv-1", id: "p1"), seq: 1)], via: machine)
        }
        let row = try #require(try await openStore(directory).conversation(key("conv-1")))
        #expect(row.lifecycleState == "running")
        #expect(row.waitingForInput)
        #expect(row.lastMessageAt == storeNow)
    }
}
