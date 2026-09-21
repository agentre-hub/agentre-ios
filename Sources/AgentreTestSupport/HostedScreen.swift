import SwiftUI
import UIKit

/// 把一屏托管进窗口，按无障碍树读出屏上可见的文字——视图层断言「现在是哪一屏」的读法。
@MainActor
public final class HostedScreen {
    private let window: UIWindow
    private let controller: UIViewController

    public init(_ view: some View, size: CGSize = CGSize(width: 390, height: 844)) {
        controller = UIHostingController(rootView: view)
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
    }

    isolated deinit {
        window.isHidden = true
    }

    /// 屏上可见的文字：SwiftUI 部分取无障碍树的标签，UIKit 部分（如系统标签栏）取可见 UILabel 的文字
    /// ——单元测试进程不加载 UIKit 的无障碍实现，系统控件在无障碍树里是空的。
    public func labels() async -> [String] {
        guard AccessibilityTree.enable() else { return [] }
        await AccessibilityTree.settle(controller.view)
        let swiftUI = AccessibilityTree.elements(in: controller.view).compactMap(\.accessibilityLabel)
        return swiftUI + AccessibilityTree.visibleLabels(in: controller.view)
    }

    /// 屏上此刻点不动的元素（无障碍树里带 notEnabled 的）的标签：断言「这个动作此刻不可用」。
    public func disabledLabels() async -> [String] {
        guard AccessibilityTree.enable() else { return [] }
        await AccessibilityTree.settle(controller.view)
        return AccessibilityTree.elements(in: controller.view)
            .filter { $0.accessibilityTraits.contains(.notEnabled) }
            .compactMap(\.accessibilityLabel)
    }
}
