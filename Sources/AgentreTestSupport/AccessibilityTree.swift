import Darwin
import UIKit

/// 读托管视图的无障碍树：命中区断言与「现在是哪一屏」都经它找元素。
@MainActor
enum AccessibilityTree {
    private static let interactiveTraits: UIAccessibilityTraits = [.button, .link, .adjustable, .searchField, .keyboardKey]

    /// SwiftUI 只在辅助功能开启时才建无障碍树。测试进程里以辅助功能自动化的开关打开它
    /// （libAccessibility 的 `_AXSSetAutomationEnabled`；仅测试目标链接本模块，不进应用）。
    static func enable() -> Bool {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled")
        else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(1)
        return true
    }

    /// 让 SwiftUI 完成布局、几何回调与无障碍树的建立。
    static func settle(_ view: UIView) async {
        for _ in 0..<5 {
            view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 可见的无障碍元素（叶子）。
    static func elements(in root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        func visit(_ node: NSObject) {
            if let view = node as? UIView, view.isHidden || view.alpha == 0 { return }
            if node.isAccessibilityElement {
                found.append(node)
                return
            }
            let children = node.accessibilityElements?.compactMap { $0 as? NSObject }
            for child in children ?? [] { visit(child) }
            if children == nil, let view = node as? UIView {
                for subview in view.subviews { visit(subview) }
            }
        }
        visit(root)
        return found
    }

    static func isInteractive(_ element: NSObject) -> Bool {
        !element.accessibilityTraits.intersection(interactiveTraits).isEmpty
    }

    /// 视图层级里可见的 UILabel 文字。
    static func visibleLabels(in root: UIView) -> [String] {
        guard !root.isHidden, root.alpha > 0 else { return [] }
        let own = (root as? UILabel)?.text.map { [$0] } ?? []
        return own + root.subviews.flatMap { visibleLabels(in: $0) }
    }

    /// 视图层级里可见、可交互的 UIKit 控件与文本输入视图。
    static func controls(in root: UIView) -> [UIView] {
        var found: [UIView] = []
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0, view.isUserInteractionEnabled else { return }
            if view is UIControl || view is UITextView {
                found.append(view)
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    /// 控件的真实命中区（窗口坐标）：从中心沿横竖两条线逐点做命中测试，量出命中测试仍落在
    /// 该控件（或其子视图）上的范围。中心就点不到它（被盖住、重复的装饰副本）时为 nil。
    static func hitRegion(of control: UIView, in window: UIWindow) -> CGRect? {
        func hits(_ point: CGPoint) -> Bool {
            guard window.bounds.contains(point), let hit = window.hitTest(point, with: nil) else { return false }
            return hit === control || hit.isDescendant(of: control)
        }
        let center = window.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), from: control)
        guard hits(center) else { return nil }
        func extent(_ step: CGVector) -> CGFloat {
            var distance: CGFloat = 0
            while hits(CGPoint(x: center.x + step.dx * (distance + 1), y: center.y + step.dy * (distance + 1))) { distance += 1 }
            return distance
        }
        let left = extent(CGVector(dx: -1, dy: 0)), right = extent(CGVector(dx: 1, dy: 0))
        let up = extent(CGVector(dx: 0, dy: -1)), down = extent(CGVector(dx: 0, dy: 1))
        return CGRect(x: center.x - left, y: center.y - up, width: left + right + 1, height: up + down + 1)
    }
}
