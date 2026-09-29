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
        // 从窗口起读：模态（新建对话）与底部面板是呈现出来的控制器，不在根控制器的视图里。
        return elements(in: window).compactMap(\.accessibilityLabel) + visibleLabels(in: window)
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
            let matches = elements(in: window).filter { element in
                guard let text = element.accessibilityLabel else { return false }
                return exact ? text == label : text.contains(label)
            }
            return matches.first { $0.accessibilityTraits.contains(.button) } ?? matches.first
        }
        guard element.accessibilityActivate() else { throw WaitTimeout(what: "activating “\(label)”") }
        await settle()
    }

    /// 切到第 `index` 个标签页：点自绘 tab 栏上按标识找到的那枚（0 消息、1 机器、2 我）。
    func selectTab(_ index: Int) async throws {
        let id = Self.tabIdentifiers[index]
        let tab: NSObject
        do {
            tab = try await eventually("tab \(id)") { () -> NSObject? in
                await settle()
                return elements(in: window).first { identifier(of: $0) == id }
            }
        } catch {
            throw WaitTimeout(what: "tab \(id); saw identifiers \(elements(in: window).compactMap { identifier(of: $0) })")
        }
        guard tab.accessibilityActivate() else { throw WaitTimeout(what: "activating \(id)") }
        await settle()
    }

    private static let tabIdentifiers = ["shell.tab.messages", "shell.tab.machines", "shell.tab.me"]

    /// 界面上此刻有没有 tab 栏元素（任何一枚 tab 按钮）。
    func hasTabBar() async -> Bool {
        await settle()
        return elements(in: window).contains { identifier(of: $0).map(Self.tabIdentifiers.contains) ?? false }
    }

    /// 等到 tab 栏在（或不在）界面上。
    func expectTabBar(_ present: Bool, _ step: String) async throws {
        do {
            _ = try await eventually("tab bar \(present ? "shown" : "gone") at \(step)", seconds: 5) {
                await hasTabBar() == present ? true : nil
            }
        } catch {
            throw WaitTimeout(what: "tab bar \(present ? "shown" : "gone") at \(step); saw \(await labels())")
        }
    }

    /// 屏上的 UIKit 文本框。
    func textFields() async -> [UITextField] {
        await settle()
        func fields(in view: UIView) -> [UITextField] {
            guard !view.isHidden, view.alpha > 0 else { return [] }
            return ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap(fields(in:))
        }
        return fields(in: window)
    }

    /// SwiftUI 的无障碍节点答得出标识，却不在类型上声明 `UIAccessibilityIdentification`：按选择子问。
    fileprivate func identifier(of element: NSObject) -> String? {
        guard element.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return element.value(forKey: "accessibilityIdentifier") as? String
    }

    fileprivate func settle() async {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    fileprivate func elements(in root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        func visit(_ node: NSObject) {
            if let view = node as? UIView, view.isHidden || view.alpha == 0 || view.accessibilityElementsHidden { return }
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

    fileprivate func visibleLabels(in root: UIView) -> [String] {
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

extension Screen {
    /// 屏上此刻看得见的导航栏文字：顶层页的大字标题与行内动作、二级页紧凑导航栏的标题——
    /// 都是自绘的外壳部件，按无障碍标识找，按用户看到的文字读出，不读环境。
    func navigationTitles() async -> [String] {
        await settle()
        return elements(in: window)
            .filter { ["shell.title", "shell.action"].contains(identifier(of: $0)) }
            .compactMap(\.accessibilityLabel)
    }
}

/// 界面文案在指定语言下的译文（与进程此刻的系统语言无关）。
func copy(_ key: String, table: String, language: String) -> String {
    let bundle = AgentreUIResources.bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    return (bundle ?? AgentreUIResources.bundle).localizedString(forKey: key, value: "⟨missing \(language):\(key)⟩", table: table)
}
