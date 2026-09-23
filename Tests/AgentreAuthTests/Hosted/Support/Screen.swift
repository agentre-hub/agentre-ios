import AgentreUI
import Darwin
import SwiftUI
import UIKit

/// 把 App 的根视图托管进一个真窗口，按无障碍树读出用户看得见的文字、按标签点按钮。
@MainActor
final class Screen {
    let window: UIWindow

    init(_ view: some View) {
        // 挂在宿主 App 的场景上：没有场景的窗口里，TabView 换进来时 UIKit 的子控制器挂不进窗口。
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        Self.enableAccessibility()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// 屏上此刻看得见的文字。
    func labels() async -> [String] {
        await settle()
        guard let root = window.rootViewController?.view else { return [] }
        return elements(in: root).compactMap(\.accessibilityLabel) + visibleLabels(in: root)
    }

    /// 等到屏上出现某段文字（子串匹配）。
    @discardableResult
    func waitFor(_ text: String, seconds: Double = 10) async throws -> [String] {
        do {
            return try await eventually("“\(text)” on screen", seconds: seconds) {
                let labels = await labels()
                return labels.contains { $0.contains(text) } ? labels : nil
            }
        } catch {
            throw WaitTimeout(what: "“\(text)” on screen; saw \(await labels())")
        }
    }

    /// 点标签等于 `label` 的那个元素（无障碍激活，与 VoiceOver 双击同一条路）。
    func tap(_ label: String, exact: Bool = true, seconds: Double = 10) async throws {
        let element = try await eventually("tappable “\(label)”", seconds: seconds) { () -> NSObject? in
            await settle()
            guard let root = window.rootViewController?.view else { return nil }
            let matches = elements(in: root).filter { element in
                guard let text = element.accessibilityLabel else { return false }
                return exact ? text == label : text.contains(label)
            }
            return matches.first { $0.accessibilityTraits.contains(.button) } ?? matches.first
        }
        guard element.accessibilityActivate() else { throw WaitTimeout(what: "activating “\(label)”") }
        await settle()
    }

    /// 切到第 `index` 个标签页（系统标签栏是 UIKit 控件，不在 SwiftUI 的无障碍树里）。
    func selectTab(_ index: Int) async throws {
        let bar = try await eventually("tab bar") { tabBarController(in: window.rootViewController) ?? tabBarController(near: window.rootViewController?.view) }
        bar.selectedIndex = index
        if let selected = bar.viewControllers?[index] {
            _ = bar.delegate?.tabBarController?(bar, shouldSelect: selected)
            bar.delegate?.tabBarController?(bar, didSelect: selected)
        }
        await settle()
    }

    /// SwiftUI 的 TabView 把 UITabBarController 的视图挂进无障碍树而不是子视图里：顺着它找控制器。
    private func tabBarController(near root: UIView?) -> UITabBarController? {
        guard let root else { return nil }
        var queue: [NSObject] = [root]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if let view = node as? UIView {
                if let bar = view.next as? UITabBarController { return bar }
                queue += view.subviews
            }
            queue += node.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
        }
        return nil
    }

    private func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let bar = controller as? UITabBarController { return bar }
        for child in controller.children {
            if let found = tabBarController(in: child) { return found }
        }
        return nil
    }

    private func settle() async {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func elements(in root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        func visit(_ node: NSObject) {
            if let view = node as? UIView, view.isHidden || view.alpha == 0 { return }
            if node.isAccessibilityElement {
                found.append(node)
                return
            }
            var children = node.accessibilityElements?.compactMap { $0 as? NSObject }
            if children?.isEmpty ?? true {
                let count = node.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    children = (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
                }
            }
            for child in children ?? [] { visit(child) }
            if children?.isEmpty ?? true, let view = node as? UIView {
                for subview in view.subviews { visit(subview) }
            }
        }
        visit(root)
        return found
    }

    private func visibleLabels(in root: UIView) -> [String] {
        guard !root.isHidden, root.alpha > 0 else { return [] }
        let own = (root as? UILabel)?.text.map { [$0] } ?? []
        return own + root.subviews.flatMap { visibleLabels(in: $0) }
    }

    /// SwiftUI 只在辅助功能开启时建无障碍树；测试进程以自动化开关打开它。
    private static func enableAccessibility() {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled")
        else { return }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(1)
    }
}

/// 界面文案的当前语言译文：断言用户看到的那句话，而不是键。
func copy(_ key: String, table: String) -> String {
    AgentreUIResources.bundle.localizedString(forKey: key, value: nil, table: table)
}
