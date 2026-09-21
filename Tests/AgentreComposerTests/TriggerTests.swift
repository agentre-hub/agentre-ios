import AgentreDomain
import Testing

/// 就地触发的判定与候选评分，规则对齐宿主 chat-input 的 slash/trigger.ts、mentions/trigger.ts
/// 与 lib/suggestion-score.ts。
@Suite("就地触发")
struct TriggerTests {
    @Test("斜杠：行首或空白之后的 / 触发，query 是 / 与光标之间的文本", arguments: [
        ("/", 0, ""), ("/com", 0, "com"), ("修一下 /dep", 4, "dep"), ("a\n/x", 2, "x"),
    ])
    func slashHits(input: String, offset: Int, query: String) {
        #expect(ComposerTrigger.detectSlash(input, triggers: ["/"]) == SlashTriggerHit(startOffset: offset, query: query, trigger: "/"))
    }

    @Test("斜杠：词内 / 不触发；query 里出现空白即结束；未启用的触发字符不算", arguments: [
        "foo/bar", "/compact now", "", "hello", "$skill",
    ])
    func slashMisses(input: String) {
        #expect(ComposerTrigger.detectSlash(input, triggers: ["/"]) == nil)
    }

    @Test("Codex 的 Skill 用 $ 触发")
    func dollar() {
        #expect(ComposerTrigger.detectSlash("跑 $rev", triggers: ["/", "$"]) == SlashTriggerHit(startOffset: 2, query: "rev", trigger: "$"))
    }

    @Test("提及：行首或空白之后的 @ 触发；邮箱形式与已结束的 query 不触发")
    func mention() {
        #expect(ComposerTrigger.detectMention("@re") == MentionTriggerHit(startOffset: 0, query: "re"))
        #expect(ComposerTrigger.detectMention("问 @") == MentionTriggerHit(startOffset: 2, query: ""))
        #expect(ComposerTrigger.detectMention("a@b.com") == nil)
        #expect(ComposerTrigger.detectMention("@re x") == nil)
    }

    @Test("评分阶梯：全等 100、前缀 80、包含 60、拼音全拼 50、首字母 40、按序 30、副标题 20、空 query 1")
    func score() {
        #expect(SuggestionScore.score(query: "compact", title: "compact") == 100)
        #expect(SuggestionScore.score(query: "com", title: "compact") == 80)
        #expect(SuggestionScore.score(query: "pac", title: "compact") == 60)
        #expect(SuggestionScore.score(query: "niandu", title: "年度报告") == 50)
        #expect(SuggestionScore.score(query: "ndbg", title: "年度报告") == 40)
        #expect(SuggestionScore.score(query: "nbg", title: "年度报告") == 30)
        #expect(SuggestionScore.score(query: "摘要", title: "compact", subtitle: "只保留摘要") == 20)
        #expect(SuggestionScore.score(query: "zzz", title: "compact") == 0)
        #expect(SuggestionScore.score(query: " ", title: "compact") == 1)
    }
}
