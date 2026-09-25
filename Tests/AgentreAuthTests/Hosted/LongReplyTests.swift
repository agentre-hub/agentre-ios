@testable import Agentre
import AgentreDomain
import AgentreStore
import AgentreUI
import Foundation
import SwiftUI
import Testing
import UIKit

/// 超长回复经 App 的整条实时路径（伪中继 → 通道 → 转录适配器 → 回合接续 → 转录模型 → 转录视图，
/// 跟随同步同时落库）到屏上：流停之后数秒内显示完全文，不积压成几分钟的落后（report-6「观察」）。
@MainActor
@Suite(.serialized)
struct LongReplyTests {
    /// 与 dev 上那一轮同形：约 1.7 万字、带空行分节的正文。
    private static let reply = (1...10).map { chapter in
        "## 第 \(chapter) 章\n\n" + (1...12).map { paragraph in
            String(repeating: "第 \(chapter) 章第 \(paragraph) 段讲网络分层里的一件事，", count: 6)
        }.joined(separator: "\n\n")
    }.joined(separator: "\n\n")

    @Test("对话屏开着时机器流完一篇上万片预览帧的长回复：流停之后数秒内屏上就是全文")
    func longReplyLandsSoonAfterTheFeedStops() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        harness.machine.add(
            FakeMachine.Session(conversationID: "conv-1", title: "Long"),
            frames: [WireNotification.userMessage("conv-1", seq: 0, "写一篇网络原理长文")]
        )
        let environment = try harness.environment()
        let key = try await environment.store.save(MachineSession(conversationID: "conv-1", title: "Long"), via: "machine-a")
        let services = environment.startServices()
        defer { Task { await environment.tearDown() } }
        _ = try await eventually("synced") { try await environment.store.latestSeq(key) == 1 ? true : nil }
        let model = try #require(await services.conversationModel(for: key))
        // 真窗口里的转录视图：屏每交一次都要重排，这一段的代价要算进来。
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: TranscriptView(model: model.transcript, agentName: "Claude Code"))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        _ = try await eventually("transcript attached") { harness.relay.calls(WireMethod.sessionAttach).count >= 2 ? true : nil }
        try await Task.sleep(for: .milliseconds(200))

        func shown() -> String {
            model.transcript.rows.compactMap { row in
                if case .text(let text, _) = row.content { text } else { nil }
            }.last ?? ""
        }
        // agentred 的形状（dev 上那一轮的 fanout 日志：795 片思考、11077 片正文，平均每片一两个字，212 秒），
        // 以约十倍于真实的节奏推：每 50 毫秒 25 片。修前实测：流停 60 秒后屏上仍只有约 6000 / 15711 字。
        let target = "machine:machine-a"
        harness.relay.notify(target, WireNotification.turnStarted("conv-1"))
        let characters = Array(Self.reply)
        var deltas = (0..<795).map { _ in WireNotification.previewThinking("conv-1", "想") }
        var index = 0
        while index < characters.count {
            let size = deltas.count.isMultiple(of: 2) ? 1 : 2
            deltas.append(WireNotification.previewText("conv-1", String(characters[index..<min(index + size, characters.count)])))
            index += size
        }
        #expect(deltas.count > 10_000)
        for start in stride(from: 0, to: deltas.count, by: 25) {
            for delta in deltas[start..<min(start + 25, deltas.count)] { harness.relay.notify(target, delta) }
            try await Task.sleep(for: .milliseconds(50))
        }
        // 收口：定稿的正文带号发出，随后是终态帧。
        let final = harness.machine.append("conv-1", [WireNotification.textDelta("conv-1", seq: 0, Self.reply)])
        harness.relay.notify(target, WireNotification.textDelta("conv-1", seq: final[0], Self.reply))
        harness.relay.notify(target, WireNotification.turnDone("conv-1"))
        let stopped = ContinuousClock.now

        do {
            _ = try await eventually("full reply on screen", seconds: 60) {
                shown() == Self.reply && !model.transcript.document.running ? true : nil
            }
        } catch {
            Issue.record("流停 60 秒后屏上仍只有 \(shown().count) / \(Self.reply.count) 字")
            return
        }
        let lag = ContinuousClock.now - stopped
        #expect(lag < .seconds(5), "流停之后过了 \(lag) 才显示完全文")
    }
}
