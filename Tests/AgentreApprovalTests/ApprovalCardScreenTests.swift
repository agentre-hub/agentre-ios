import AgentreDesign
import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import Foundation
import SwiftUI
import Testing

/// 卡片接在转录的插入点上的视图层断言：读得到的事实、三档处置的顺序与分量、命中区。
@MainActor
@Suite("审批卡片")
struct ApprovalCardScreenTests {
    let port = FakeAnswering()

    func cards() -> ApprovalCardsModel { ApprovalCardsModel(conversation: savedConversation, answering: port) }

    func labels(_ events: [TranscriptEvent], cards: ApprovalCardsModel, language: String = "zh-Hans") async -> [String] {
        let model = await transcript(ending: events)
        return await HostedScreen(screen(model, cards: cards, language: language)).labels()
    }

    /// `needles` 按给定顺序出现在 `haystack` 里。
    func inOrder(_ needles: [String], in haystack: [String]) -> Bool {
        var rest = haystack[...]
        for needle in needles {
            guard let at = rest.firstIndex(of: needle) else { return false }
            rest = haystack[(at + 1)...]
        }
        return true
    }

    @Test("内联在转录里：请求种类、执行目录、$ 与命令，其后是宿主原文的三档处置，自左到右拒绝 / 本会话始终允许 / 仅本次允许", arguments: ["zh-Hans", "en"])
    func inlineCard(language: String) async throws {
        let request = permission(input: ["command": "pnpm test --filter ui"])
        let seen = await labels([.permissionRequest(request)], cards: cards(), language: language)
        let dispositions = try ["permission.reject", "permission.allowForSession", "permission.allowOnce"].map { try text($0, language) }
        #expect(seen.contains("需要你批准。"), "卡片在转录流里，与前文同屏：\(seen)")
        #expect(inOrder(["Bash", "/Users/dev/agentre", "$", "pnpm test --filter ui"] + dispositions, in: seen), "\(seen)")
    }

    @Test("三档的视觉分量：描边、浅底、主色实心")
    func weights() {
        #expect(PermissionDisposition.allCases.map(\.weight) == [.outline, .tinted, .solid])
    }

    @Test("别的工具：输入以缩进 JSON 单独成块")
    func otherToolInput() async {
        let request = permission(tool: "Write", input: ["path": "/repo/a.txt"])
        let seen = await labels([.permissionRequest(request)], cards: cards())
        #expect(seen.contains("Write"))
        #expect(seen.contains("{\n  \"path\": \"/repo/a.txt\"\n}"), "\(seen)")
    }

    @Test("输入过长时先给摘要并可展开；展开后是完整输入")
    func longInputCollapses() async throws {
        let command = (1...12).map { "echo step-\($0)" }.joined(separator: "\n")
        let request = permission(input: ["command": .string(command)])
        let model = cards()
        let collapsed = await labels([.permissionRequest(request)], cards: model)
        #expect(collapsed.contains("echo step-1"), "\(collapsed)")
        #expect(!collapsed.contains(command))
        #expect(collapsed.contains(try text("input.expand", "zh-Hans")))

        model.toggleExpanded("p1")
        let expanded = await labels([.permissionRequest(request)], cards: model)
        #expect(expanded.contains(command), "\(expanded)")
        #expect(expanded.contains(try text("input.collapse", "zh-Hans")))
    }

    @Test("落定后不再给处置，只标出决定", arguments: [
        (PermissionDisposition.reject, "permission.denied"),
        (.allowForSession, "permission.allowedForSession"),
        (.allowOnce, "permission.allowed"),
    ])
    func settledCard(disposition: PermissionDisposition, label: String) async throws {
        let model = cards()
        await model.submit(disposition, for: permission())
        let seen = await labels([.permissionRequest(permission())], cards: model)
        #expect(seen.contains(try text(label, "zh-Hans")), "\(seen)")
        #expect(!seen.contains(try text("permission.allowOnce", "zh-Hans")))
        #expect(!seen.contains(try text("permission.reject", "zh-Hans")))
    }

    @Test("没送达的作答如实标出，处置仍在")
    func failedCard() async throws {
        let model = cards()
        await port.setFailing(true)
        await model.submit(.allowOnce, for: permission())
        let seen = await labels([.permissionRequest(permission())], cards: model)
        #expect(seen.contains(try text("permission.submitFailed", "zh-Hans")), "\(seen)")
        #expect(seen.contains(try text("permission.allowOnce", "zh-Hans")))
    }

    @Test("三枚处置按钮：命中区各 44×44，同一行右对齐、按标签宽度排；两枚允许之间留出死区；发现数 = 放置数")
    func dispositionHitTargets() async throws {
        let model = await transcript(ending: [.permissionRequest(permission())])
        let report = await hitTargetReport(of: screen(model, cards: cards(), language: "zh-Hans"))
        #expect(report.violations.isEmpty, "\(report.violations)")
        try #require(report.targets.count == 3, "放了三枚处置按钮：\(report.targets)")
        let row = report.targets.sorted { $0.minX < $1.minX }
        for target in row {
            #expect(target.width >= 44 && target.height >= 44, "\(target)")
            #expect(abs(target.midY - row[0].midY) < 0.5, "同一行：\(row)")
            #expect(target.width < 195, "按标签宽度排，不做通栏：\(target)")
        }
        #expect(gap(row[0], row[1]) >= 8, "拒绝与本会话始终允许不相接：\(row)")
        #expect(gap(row[1], row[2]) >= 8, "本会话始终允许与仅本次允许之间的死区：\(row)")
        #expect(row[2].maxX > 390 - 16 - 24, "右对齐：\(row)")
    }

    @Test("英文标签排不下一行时换行排，死区照留；发现数 = 放置数")
    func dispositionHitTargetsEnglish() async throws {
        let model = await transcript(ending: [.permissionRequest(permission())])
        let report = await hitTargetReport(of: screen(model, cards: cards(), language: "en"))
        #expect(report.violations.isEmpty, "\(report.violations)")
        try #require(report.targets.count == 3, "\(report.targets)")
        for (i, a) in report.targets.enumerated() {
            #expect(a.width >= 44 && a.height >= 44, "\(a)")
            for b in report.targets[(i + 1)...] { #expect(gap(a, b) >= 8, "\(a) \(b)") }
        }
    }

    @Test("长输入的展开按钮也补满命中区、不与处置相接；发现数 = 放置数")
    func expandHitTarget() async throws {
        let command = (1...12).map { "echo step-\($0)" }.joined(separator: "\n")
        let model = await transcript(ending: [.permissionRequest(permission(input: ["command": .string(command)]))])
        let report = await hitTargetReport(of: screen(model, cards: cards(), language: "zh-Hans"))
        #expect(report.violations.isEmpty, "\(report.violations)")
        #expect(report.targets.count == 4, "展开 + 三枚处置：\(report.targets)")
    }

    @Test("任何位置都不判定危险：同一张卡换成 rm -rf，除命令本身外读到的一字不差")
    func noDangerHeuristic() async {
        let benign = await labels([.permissionRequest(permission(input: ["command": "ls"]))], cards: cards())
        let drastic = await labels([.permissionRequest(permission(input: ["command": "sudo rm -rf /"]))], cards: cards())
        #expect(benign.map { $0 == "ls" ? "⟨cmd⟩" : $0 } == drastic.map { $0 == "sudo rm -rf /" ? "⟨cmd⟩" : $0 })
    }

    // MARK: 提问

    @Test("AskUserQuestion 复用同一形态：请求种类、问题、作答框，跳过与提交回复右对齐")
    func questionCard() async throws {
        let seen = await labels([.questionRequest(question())], cards: cards())
        #expect(inOrder(["user_ask", "用哪个分支？", try text("question.skip", "zh-Hans"), try text("question.submit", "zh-Hans")], in: seen), "\(seen)")
    }

    @Test("提问卡：两枚按钮与作答框各补满 44×44、互不重叠；发现数 = 放置数")
    func questionHitTargets() async throws {
        let model = await transcript(ending: [.questionRequest(question())])
        let report = await hitTargetReport(of: screen(model, cards: cards(), language: "zh-Hans"))
        #expect(report.violations.isEmpty, "\(report.violations)")
        #expect(report.targets.count == 3, "跳过、提交回复、作答框：\(report.targets)")
    }

    @Test("提问落定后只标出结果", arguments: [(true, "question.skipped"), (false, "question.answered")])
    func settledQuestion(skipped: Bool, label: String) async throws {
        let model = cards()
        model.setAnswer("main", at: 0, of: question())
        if skipped { await model.skip(question()) } else { await model.submitAnswers(for: question()) }
        let seen = await labels([.questionRequest(question())], cards: model)
        #expect(seen.contains(try text(label, "zh-Hans")), "\(seen)")
        #expect(!seen.contains(try text("question.submit", "zh-Hans")))
    }

    @Test("提问没送达：标为已失效并如实写明")
    func expiredQuestion() async throws {
        let model = cards()
        model.setAnswer("main", at: 0, of: question())
        await port.setFailing(true)
        await model.submitAnswers(for: question())
        let seen = await labels([.questionRequest(question())], cards: model)
        #expect(seen.contains(try text("question.expired", "zh-Hans")), "\(seen)")
        #expect(seen.contains(try text("question.expiredDetail", "zh-Hans")), "\(seen)")
    }
}

/// 源码层的守卫：卡片不升起模态，也没有任何按内容判定危险的写法。
@Suite("审批卡片源码")
struct ApprovalSourceGuardTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func sources() throws -> [(String, String)] {
        try ["Sources/AgentreUI/Conversation/Cards", "Sources/AgentreDomain/Approval"].flatMap { dir -> [(String, String)] in
            let url = Self.root.appending(path: dir)
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
                .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        }
    }

    @Test("不升起模态、不按内容判定危险")
    func noModalNoHeuristic() throws {
        let files = try sources()
        #expect(files.count >= 3, "扫描范围为空：\(Self.root.path)")
        let forbidden = try Regex(#"\.(sheet|fullScreenCover|alert|confirmationDialog|popover)\s*\(|(?i:danger|destructive|risky|rm -rf|sudo)"#)
        for (name, source) in files where source.contains(forbidden) {
            Issue.record("\(name) 含 \(source.firstMatch(of: forbidden).map { String(source[$0.range]) } ?? "")")
        }
    }
}
