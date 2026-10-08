import AgentreDomain
import Testing

/// 更多面板取值的显示形（纯函数，规格「04 更多面板」）：权限模式与思考档位的已知档位认得出来，
/// 表外原样；上下文行的「已用k/上限k」摘要。
@Suite("面板显示取值")
struct ComposerDisplayTests {
    @Test("权限档位：四个已知档位认得出来，表外原样")
    func permissionModeDisplay() {
        #expect(PermissionModeDisplay("default") == .standard(.`default`))
        #expect(PermissionModeDisplay("acceptEdits") == .standard(.acceptEdits))
        #expect(PermissionModeDisplay("plan") == .standard(.plan))
        #expect(PermissionModeDisplay("bypassPermissions") == .standard(.bypassPermissions))
        #expect(PermissionModeDisplay("sudo") == .raw("sudo"))
        #expect(PermissionModeDisplay("") == .raw(""))
    }

    @Test("思考档位：低/中/高认得出来，执行端报出的更高档（如 xhigh）原样")
    func reasoningEffortDisplay() {
        #expect(ReasoningEffortDisplay("low") == .standard(.low))
        #expect(ReasoningEffortDisplay("medium") == .standard(.medium))
        #expect(ReasoningEffortDisplay("high") == .standard(.high))
        #expect(ReasoningEffortDisplay("xhigh") == .raw("xhigh"))
        #expect(ReasoningEffortDisplay("max") == .raw("max"))
    }

    @Test("上下文摘要：已用与上限各自四舍五入到千，拼成「已用k/上限k」")
    func contextCompactSummary() {
        #expect(ContextUsage(used: 79_312, max: 200_000).compactSummary == "79k/200k")
        #expect(ContextUsage(used: 40_000, max: 100_000).compactSummary == "40k/100k")
        // 不足 500 的余数四舍五入到 0k，不到负数。
        #expect(ContextUsage(used: 400, max: 100_000).compactSummary == "0k/100k")
    }
}
