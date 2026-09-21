import AgentreDesign
import Darwin
import SwiftUI
import UIKit

/// 一屏上的可点区域（窗口坐标）与违规。
public struct HitTargetReport: Sendable {
    public var targets: [CGRect]
    public var violations: [String]
}

public struct HitTargetViolations: Error, CustomStringConvertible {
    public let violations: [String]
    public var description: String { violations.joined(separator: "\n") }
}

/// 把一屏托管进窗口、布局完毕，收集它的全部可点区域，并逐一核对：
///
/// - 可点元素取自无障碍树（按钮、链接、可调节、搜索框等特征）——不靠视图自报，
///   漏加修饰符的按钮照样被找到；
/// - SwiftUI 的可点元素必须经 `Button.hitTarget()` 登记，其命中区取登记的那块
///   （补满之后的真实点击区）；未登记即违规，哪怕它的无障碍框够大——在按钮外面补
///   `.frame` 撑得大无障碍框，却撑不大点击区；
/// - UIKit 提供的控件（如系统标签栏按钮、文本框）以窗口的命中测试逐点量出真实命中区
///   （被别的视图盖住、实际点不到的控件不计）；
/// - 每块命中区不小于 44×44pt，任意两块互不重叠（仅共边不算重叠）。
@MainActor
public func hitTargetReport(of view: some View, size: CGSize = CGSize(width: 390, height: 844)) async -> HitTargetReport {
    guard AccessibilityTree.enable() else {
        return HitTargetReport(targets: [], violations: ["无法打开无障碍树（_AXSSetAutomationEnabled 不可用）：命中区无从核对"])
    }
    let collector = HitTargetCollector()
    let controller = UIHostingController(rootView: view.environment(\.hitTargetCollector, collector))
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true }

    await AccessibilityTree.settle(controller.view)

    let registered = Array(collector.frames.values)
    var targets: [CGRect] = []
    var violations: [String] = []

    // SwiftUI 的可点元素：只能从无障碍树里找到；命中区取 hitTarget() 登记的那块。
    for element in AccessibilityTree.elements(in: controller.view) where !(element is UIView) && AccessibilityTree.isInteractive(element) {
        let frame = window.convert(element.accessibilityFrame, from: nil)
        let name = element.accessibilityLabel ?? "?"
        guard let match = registered.first(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(frame) }) else {
            targets.append(frame)
            violations.append("「\(name)」未经 hitTarget() 补满命中区：\(frame)")
            continue
        }
        targets.append(match)
        if match.width < minimumHitTargetSide - 0.5 || match.height < minimumHitTargetSide - 0.5 {
            violations.append("「\(name)」命中区小于 44×44：\(match)")
        }
    }

    // UIKit 的控件（系统标签栏按钮、文本框等）：命中区以窗口的真实命中测试量出。
    for control in AccessibilityTree.controls(in: controller.view) {
        guard let region = AccessibilityTree.hitRegion(of: control, in: window) else { continue }
        targets.append(region)
        if region.width < minimumHitTargetSide - 0.5 || region.height < minimumHitTargetSide - 0.5 {
            violations.append("「\(control.accessibilityLabel ?? String(describing: type(of: control)))」命中区小于 44×44：\(region)")
        }
    }

    for i in targets.indices {
        for j in targets.indices where j > i {
            let overlap = targets[i].intersection(targets[j])
            if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 {
                violations.append("命中区重叠：\(targets[i]) 与 \(targets[j])")
            }
        }
    }
    return HitTargetReport(targets: targets, violations: violations)
}

/// 断言一屏的每个可点区域都不小于 44×44pt，且任意两个互不重叠。
@MainActor
public func assertHitTargets(_ view: some View, size: CGSize = CGSize(width: 390, height: 844)) async throws {
    let report = await hitTargetReport(of: view, size: size)
    if !report.violations.isEmpty { throw HitTargetViolations(violations: report.violations) }
}

