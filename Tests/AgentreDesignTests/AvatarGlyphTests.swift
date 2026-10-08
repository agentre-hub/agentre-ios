import AgentreDesign
import AgentreDomain
@testable import AgentreUI
import CoreGraphics
import Testing

/// `AvatarGlyph` 该画什么色块与字，按 `IdentityGlyph` 的四种取舍逐一核对（规格「全局框架」头像字形一条）。
struct AvatarGlyphTests {
    @Test("身份档：填对应的 agent token，字母原样带出")
    func identityFillsItsToken() {
        let appearance = AvatarGlyphAppearance(.identity(letter: "F", color: .slot(4)))
        #expect(appearance.fill == .identity(.agent4))
        #expect(appearance.letter == "F")
    }

    @Test("身份档字母为空（Agent 名为空）：不填字，颜色仍照常")
    func identityWithNoLetterStillFillsColor() {
        let appearance = AvatarGlyphAppearance(.identity(letter: nil, color: .slot(11)))
        #expect(appearance.fill == .identity(.agent11))
        #expect(appearance.letter == nil)
    }

    @Test("中性字形：中性填色，不带字")
    func neutralHasNoLetter() {
        let appearance = AvatarGlyphAppearance(.neutral)
        #expect(appearance.fill == .neutral)
        #expect(appearance.letter == nil)
    }

    @Test("中性字形填的是 agent-neutral，不是空白字形那样的底色（report-17 G4：无项目会话画成了 surface-2）")
    func neutralFillsAgentNeutral() {
        #expect(AvatarGlyphAppearance(.neutral).fill.token == .agentNeutral)
    }

    @Test("身份档填它自己的 token；空白不填任何色")
    func identityAndBlankFillTokens() {
        #expect(AvatarGlyphAppearance(.identity(letter: "F", color: .slot(4))).fill.token == .agent4)
        #expect(AvatarGlyphAppearance(.blank).fill.token == nil)
    }

    @Test("空白字形：不填任何身份色（只描边），不带字——不能与中性字形混淆")
    func blankIsNotNeutral() {
        let appearance = AvatarGlyphAppearance(.blank)
        #expect(appearance.fill == .blank)
        #expect(appearance.fill != .neutral)
        #expect(appearance.letter == nil)
    }

    @Test("agent-1…agent-16 逐一映射到对应的 ColorToken", arguments: Array(1...16))
    func slotMapsToItsToken(slot: Int) {
        let expected: [ColorToken] = [
            .agent1, .agent2, .agent3, .agent4, .agent5, .agent6, .agent7, .agent8,
            .agent9, .agent10, .agent11, .agent12, .agent13, .agent14, .agent15, .agent16,
        ]
        #expect(IdentityColor.slot(slot).token == expected[slot - 1])
    }

    @Test("中性身份色映射到 agentNeutral")
    func neutralMapsToAgentNeutralToken() {
        #expect(IdentityColor.neutral.token == .agentNeutral)
    }

    @Test("圆角与字号随边长等比，与稿子三档逐一相符", arguments: [
        (CGFloat(50), CGFloat(16), CGFloat(15)),
        (CGFloat(42), CGFloat(13), CGFloat(13)),
        (CGFloat(34), CGFloat(11), CGFloat(11.5)),
    ])
    func metricsFollowTheDesign(size: CGFloat, corner: CGFloat, letter: CGFloat) {
        let metrics = AvatarGlyphMetrics(size: size)
        #expect(abs(metrics.cornerRadius - corner) < 0.5)
        #expect(abs(metrics.letterSize - letter) < 0.5)
    }
}
