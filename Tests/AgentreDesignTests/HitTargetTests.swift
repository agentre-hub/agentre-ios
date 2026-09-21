import AgentreDesign
import AgentreTestSupport
import SwiftUI
import Testing

@MainActor
struct HitTargetTests {
    @Test("绘制 24pt 的筛选芯片与 16pt 的图标，经修饰符后命中区都是 44×44，相邻而不重叠")
    func modifierExpandsSmallControls() async throws {
        let screen = HStack(spacing: 0) {
            Button {} label: { Text(verbatim: "A").frame(height: 24) }.hitTarget()
            Button {} label: { Image(systemName: "xmark").frame(width: 16, height: 16) }.hitTarget()
        }
        let report = await hitTargetReport(of: screen)

        #expect(report.targets.count == 2)
        for target in report.targets {
            #expect(target.width >= 44 && target.height >= 44, "\(target)")
        }
        #expect(report.violations.isEmpty, "\(report.violations)")
        try await assertHitTargets(screen)
    }

    @Test("没加修饰符的小按钮：被识别为可点元素并报尺寸不足")
    func unmodifiedSmallButtonIsCaught() async {
        let screen = HStack {
            Button {} label: { Text(verbatim: "A") }.hitTarget()
            Button {} label: { Image(systemName: "xmark").frame(width: 16, height: 16) }
        }
        let report = await hitTargetReport(of: screen)

        #expect(report.targets.count == 2)
        #expect(report.violations.count == 1, "\(report.violations)")
        await #expect(throws: HitTargetViolations.self) { try await assertHitTargets(screen) }
    }

    @Test("在按钮外面补 frame 不算：无障碍框是 44 但真实命中区没扩，未登记即违规")
    func frameOutsideTheButtonIsCaught() async {
        let screen = Button {} label: { Image(systemName: "xmark").frame(width: 16, height: 16) }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        let report = await hitTargetReport(of: screen)

        #expect(report.targets.count == 1)
        #expect(report.violations.count == 1, "\(report.violations)")
    }

    @Test("两块命中区重叠：报重叠")
    func overlapIsCaught() async {
        let screen = HStack(spacing: -10) {
            Button {} label: { Text(verbatim: "A") }.hitTarget()
            Button {} label: { Text(verbatim: "B") }.hitTarget()
        }
        let report = await hitTargetReport(of: screen)

        #expect(report.targets.count == 2)
        #expect(report.violations.count == 1, "\(report.violations)")
    }

    @Test("命中区即绘制之外补满的那块：修饰符报告的区域就是可点元素的无障碍框")
    func reportedRegionIsTheControl() async {
        let screen = Button {} label: { Image(systemName: "plus").frame(width: 20, height: 20) }.hitTarget()
        let report = await hitTargetReport(of: screen)

        #expect(report.targets.count == 1)
        #expect(report.targets.first.map { $0.width == 44 && $0.height == 44 } == true, "\(report.targets)")
    }
}
