import AgentreDomain
import Foundation
import Testing

/// 选 Agent 那屏每行的解析结果，与「最近用过」、会话号、标题。
@Suite("Agent 行与发起前的纯规则")
struct AgentTargetTests {
    @Test("可用时说当前落到哪台机器；「本机」相对档说本机")
    func availableSaysWhereItLands() {
        let named = agent("a", targets: [
            ExecTarget(rank: 1, deviceName: "studio", availability: .offline),
            ExecTarget(rank: 2, deviceName: "mini", availability: .available, current: true),
        ])
        #expect(named.targetSummary == .landsOn(device: "mini"))
        let local = agent("b", targets: [ExecTarget(rank: 1, deviceUnspecified: true, availability: .available, current: true)])
        #expect(local.targetSummary == .landsOnThisDevice)
    }

    @Test("跑不了时给第一档说得出原因的那一档，跳过「本机」相对档")
    func unavailableGivesTheSpecificReason() {
        let blocked = agent("a", targets: [
            ExecTarget(rank: 1, deviceUnspecified: true, availability: .noDevice),
            ExecTarget(rank: 2, deviceName: "studio", availability: .offline),
            ExecTarget(rank: 3, availability: .unpaired),
        ])
        #expect(blocked.targetSummary == .unavailable(device: "studio", reason: .offline))
        let unpaired = agent("b", targets: [ExecTarget(rank: 1, availability: .unpaired)])
        #expect(unpaired.targetSummary == .unavailable(device: "", reason: .unpaired))
        let onlyLocal = agent("c", targets: [ExecTarget(rank: 1, deviceUnspecified: true, availability: .noDevice)])
        #expect(onlyLocal.targetSummary == .unavailable(device: "", reason: .noDevice))
    }

    @Test("链为空时说不出任何机器")
    func emptyChain() {
        #expect(agent("a", targets: []).targetSummary == .noTarget)
    }

    @Test("服务端的取值逐一对上，不认得的按不可用对待")
    func availabilityFromWire() {
        #expect(TargetAvailability(wire: "available") == .available)
        #expect(TargetAvailability(wire: "offline") == .offline)
        #expect(TargetAvailability(wire: "unpaired") == .unpaired)
        #expect(TargetAvailability(wire: "no_device") == .noDevice)
        #expect(TargetAvailability(wire: "project_path_missing") == .projectPathMissing)
        #expect(!TargetAvailability(wire: "sleeping").isAvailable)
    }

    @Test("最近用过：按最后活动由新到旧、同一 Agent 只出一次、只取清单里还在的、至多三个")
    func recentAgents() {
        let agents = ["a", "b", "c", "d", "e"].map { agent($0) }
        let conversations = [
            saved("1", agent: "a", last: 100),
            saved("2", agent: "b", last: 500),
            saved("3", agent: "a", last: 600),
            saved("4", agent: "gone", last: 700),
            saved("5", agent: "", last: 800),
            saved("6", agent: "c", last: 300),
            saved("7", agent: "d", last: 200),
        ]
        #expect(RecentAgents.pick(from: conversations, agents: agents).map(\.syncID) == ["a", "b", "c"])
        #expect(RecentAgents.pick(from: [], agents: agents).isEmpty)
    }

    @Test("会话号是 UUIDv7：规范小写带连字符，前 48 位是铸号那一刻的毫秒，两次不同")
    func mintsUUIDv7() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000.123)
        let id = ConversationIDs.mint(now: now)
        #expect(id.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil, "\(id)")
        let hex = id.replacingOccurrences(of: "-", with: "")
        #expect(UInt64(hex.prefix(12), radix: 16) == 1_900_000_000_123)
        #expect(ConversationIDs.mint(now: now) != id)
    }

    @Test("标题取第一句话的首行，过长截断")
    func titleFromFirstMessage() {
        #expect(conversationTitle(from: "  修一下构建\n细节在日志里 ") == "修一下构建")
        // 从 Windows / 网页粘进来的 CRLF 换行同样是换行。
        #expect(conversationTitle(from: "修一下构建\r\n细节在日志里") == "修一下构建")
        let long = String(repeating: "长", count: 70)
        #expect(conversationTitle(from: long) == String(repeating: "长", count: 60) + "…")
    }

    @Test("项目下的落点取自这个项目的派发计划：挑中了写机器与工作目录，挑不中写第一档说得出原因的那一档")
    func projectLanding() {
        #expect(plan(for: DispatchPlanQuery(agentSyncID: "a", projectSyncID: "fe")).landing == .landsOn(device: "mini", cwd: "/srv/fe"))
        let blocked = DispatchPlan(agentSyncID: "a", tiers: [
            DispatchTier(rank: 1, backendSyncID: "b0", availability: .unpaired),
            DispatchTier(rank: 2, backendSyncID: "b1", deviceName: "laptop", availability: .projectPathMissing),
        ], chosen: nil)
        #expect(blocked.landing == .unavailable(device: "laptop", reason: .projectPathMissing))
        let nameless = DispatchPlan(agentSyncID: "a", tiers: [DispatchTier(rank: 1, availability: .noDevice)], chosen: nil)
        #expect(nameless.landing == .unavailable(device: "", reason: .noDevice))
        #expect(DispatchPlan(agentSyncID: "a", tiers: [], chosen: nil).landing == .noTarget)
    }

    @Test("Pi 后端的 permission_mode 在派发时承载归属令牌：它不提供权限模式这一项")
    func piOffersNoPermissionMode() {
        #expect(choice("mini", backend: "b").offersPermissionMode)
        let pi = DispatchChoice(deviceFingerprint: "fp", deviceName: "mini", backendType: "piagent", kind: "agentred")
        #expect(!pi.offersPermissionMode)
    }
}
