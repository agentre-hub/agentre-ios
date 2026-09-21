import AgentreDomain
import Testing

/// 上下文用量取值：逐条移植宿主 agentre-ui/src/composer/context-usage.test.ts，
/// 三档变色逐条移植 usage-level.ts（90 / 75）与 context-meter.tsx 的「按比例不按取整」。
@Suite("上下文用量取值")
struct ContextUsageTests {
    let assistant = { (tokens: Int) in TranscriptMessage(id: "a", role: .assistant, totalInputTokens: tokens) }
    let user = { (tokens: Int) in TranscriptMessage(id: "u", role: .user, totalInputTokens: tokens) }

    @Test("Given contextWindow 不为正, When 取用量, Then 返回 nil（整块不渲染）")
    func nonPositiveWindow() {
        #expect(ContextUsage.compute(messages: [assistant(5)], contextWindow: 0) == nil)
        #expect(ContextUsage.compute(messages: [assistant(5)], contextWindow: -1) == nil)
    }

    @Test("Given 尾部是 user 与零 token 的 assistant, When 取用量, Then 跳过它们取更早那条 assistant")
    func skipsTail() {
        #expect(ContextUsage.compute(messages: [assistant(5), user(9), assistant(0)], contextWindow: 100) == ContextUsage(used: 5, max: 100))
    }

    @Test("Given 没有任何带 token 的 assistant, When 取用量, Then 是 0/max 占位而不是 nil")
    func placeholder() {
        #expect(ContextUsage.compute(messages: [], contextWindow: 100) == ContextUsage(used: 0, max: 100))
        #expect(ContextUsage.compute(messages: [assistant(0)], contextWindow: 100) == ContextUsage(used: 0, max: 100))
        #expect(ContextUsage.compute(messages: [user(9)], contextWindow: 100) == ContextUsage(used: 0, max: 100))
    }

    @Test("三档：<75 正常、≥75 告警、≥90 危急；空值不告警")
    func levels() {
        #expect(UsageLevel(percent: nil) == .ok)
        #expect(UsageLevel(percent: 74.9) == .ok)
        #expect(UsageLevel(percent: 75) == .warn)
        #expect(UsageLevel(percent: 89.9) == .warn)
        #expect(UsageLevel(percent: 90) == .danger)
        #expect(UsageLevel(percent: 100) == .danger)
    }

    @Test("定档按比例而不按取整后的百分比：89.5% 仍是告警、百分比显示为 90；超过上限封顶 100%")
    func levelUsesRatio() {
        let usage = ContextUsage(used: 895, max: 1000)
        #expect(usage.level == .warn)
        #expect(usage.percent == 90)
        #expect(ContextUsage(used: 2000, max: 1000).percent == 100)
        #expect(ContextUsage(used: 2000, max: 1000).level == .danger)
        #expect(ContextUsage(used: -5, max: 1000).fraction == 0)
    }
}
