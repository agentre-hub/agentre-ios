import AgentreDomain
import Foundation
import Testing

/// 头像字形的纯函数（规格「全局框架」头像字形一条、决策 21、测试决策「头像字形与身份色」）：
/// 宿主 `initialOf` / `getAgentInitials` / `agent-color.ts` 的用例逐条对齐。
@Suite("头像字形与身份色（纯函数）")
struct IdentityGlyphTests {
    // MARK: 项目首字（宿主 initialOf：原样大小写，空名不编字母）

    @Test("项目首字原样大小写，不像 Agent 那样强制大写", arguments: [
        ("agentre", "a"), ("Frontend", "F"), ("  server", "s"), ("组件", "组"),
    ])
    func projectInitialKeepsCase(name: String, expected: String) {
        #expect(projectInitial(name) == expected)
    }

    @Test("空名或纯空白不编一个字母出来", arguments: ["", "   ", "\n\t"])
    func projectInitialOfEmptyNameIsNil(name: String) {
        #expect(projectInitial(name) == nil)
    }

    // MARK: Agent 首字母（宿主 getAgentInitials，例外：空名不给 "?"）

    @Test("两个拉丁/数字开头的词各取首字母大写", arguments: [
        ("Code Reviewer", "CR"), ("front end", "FE"), ("gpt 4", "G4"),
    ])
    func agentInitialPairsLatinWords(name: String, expected: String) {
        #expect(agentInitial(name) == expected)
    }

    @Test("只有第一个词是拉丁/数字开头不算拼两个：CEO 助手 取首字大写而不是 C助")
    func agentInitialDoesNotPairMixedScripts() {
        #expect(agentInitial("CEO 助手") == "C")
    }

    @Test("单个词取首字大写", arguments: [("claude", "C"), ("审核", "审")])
    func agentInitialSingleWordTakesFirstCharacter(name: String, expected: String) {
        #expect(agentInitial(name) == expected)
    }

    @Test("空名或纯空白不编一个字母出来——与宿主不同：这里不给 \"?\"", arguments: ["", "   "])
    func agentInitialOfEmptyNameIsNil(name: String) {
        #expect(agentInitial(name) == nil)
    }

    // MARK: 身份色（宿主 agent-color.ts：agent-1…agent-16 解析到对应档，其余中性）

    @Test("agent-1…agent-16 逐一解析到对应档", arguments: 1...16)
    func identityColorParsesEachSlot(slot: Int) {
        #expect(IdentityColor(wireToken: "agent-\(slot)") == .slot(slot))
    }

    @Test("缺失、空串、越界、裸色值或不在词汇表里的写法（前导零、正号）一律中性——宿主按词汇表全集逐字认",
          arguments: [nil, "", "agent-0", "agent-17", "agent-1x", "#3B6896", "neutral", "agent-01", "agent-+3", "AGENT-3"] as [String?])
    func identityColorFallsBackToNeutral(token: String?) {
        #expect(IdentityColor(wireToken: token) == .neutral)
    }

    // MARK: 头像字形的取舍（项目 / Agent / 中性 / 空白）

    @Test("项目解出来了：用它的身份色加项目首字")
    func projectGlyphResolved() {
        let project = WorkspaceProject(syncID: "p1", name: "Frontend")
        var withColor = project
        withColor.color = .slot(3)
        let glyph = IdentityGlyph.project("p1", in: [withColor])
        #expect(glyph == .identity(letter: "F", color: .slot(3)))
    }

    @Test("没挂项目（空 syncID）：中性字形，即使项目树已经取到")
    func projectGlyphNoneIsNeutral() {
        #expect(IdentityGlyph.project("", in: []) == .neutral)
    }

    @Test("没挂项目（空 syncID）且项目树还没取到：仍是中性字形——空白只给挂着项目的会话")
    func projectGlyphNoneBeforeDirectoryLoadsIsNeutral() {
        #expect(IdentityGlyph.project("", in: nil) == .neutral)
    }

    @Test("项目树已经取到，但这个 syncID 不在其中：中性字形")
    func projectGlyphMissingFromLoadedListIsNeutral() {
        let project = WorkspaceProject(syncID: "other", name: "X")
        #expect(IdentityGlyph.project("p1", in: [project]) == .neutral)
    }

    @Test("挂着项目，但项目树一次都还没取到（nil）：空白字形，不是中性")
    func projectGlyphUnresolvedIsBlank() {
        #expect(IdentityGlyph.project("p1", in: nil) == .blank)
    }

    @Test("Agent 字形：它自己的身份色加 Agent 首字母规则")
    func agentGlyphResolved() {
        var target = agent("coder")
        target.name = "Code Reviewer"
        target.avatarColor = .slot(9)
        #expect(IdentityGlyph.agent(target) == .identity(letter: "CR", color: .slot(9)))
    }

    @Test("Agent 名为空：不编字母，颜色仍照常")
    func agentGlyphEmptyNameHasNoLetter() {
        var target = agent("coder")
        target.name = ""
        target.avatarColor = .slot(2)
        #expect(IdentityGlyph.agent(target) == .identity(letter: nil, color: .slot(2)))
    }
}
