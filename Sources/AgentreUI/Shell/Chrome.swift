import AgentreDesign
import SwiftUI
import UIKit

/// 标题区里的行内图标动作（顶层页右上、二级页导航栏右侧）：`primary` 色线性图标，不套系统的圆形玻璃按钮。
/// 绘制尺寸按稿子，命中区补满 44×44。
public struct ChromeIconButton: View {
    private let icon: AgentreIcon
    private let label: Text
    private let size: CGFloat
    private let action: () -> Void

    /// - Parameters:
    ///   - label: 读屏标签（图标没有文字）。
    ///   - size: 图标的绘制边长：顶层页 22，二级页导航栏 21。
    public init(_ icon: AgentreIcon, label: Text, size: CGFloat = 22, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(icon)
                .resizable()
                .frame(width: size, height: size)
                .foregroundStyle(.token(.primary))
                .accessibilityHidden(true)
        }
        .hitTarget()
        .accessibilityLabel(label)
        .accessibilityIdentifier("shell.action")
    }
}

/// 图标命中区补满 44 后比绘制宽出的那半边：行内动作据此往外挪，图标本身仍与稿子的边距对齐。
private func hitOverhang(_ drawn: CGFloat) -> CGFloat {
    (minimumHitTargetSide - drawn) / 2
}

// MARK: 顶层页标题

/// 顶层页（消息、机器、我）的头部：左对齐的大字标题，右上是行内图标动作。
/// 没有系统大标题的收缩行为（规格「全局框架」）。
public struct TopLevelHeader<Actions: View>: View {
    private let title: Text
    private let actions: Actions

    public init(_ title: Text, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            title
                .font(.agentre(.display))
                .foregroundStyle(.token(.ink))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("shell.title")
            Spacer(minLength: 0)
            // 相邻两枚的命中区各 44、恰好相接不重叠；稿子 12 的间距让位给命中区。
            HStack(spacing: 0) { actions }
                .padding(.trailing, -hitOverhang(22))
        }
        .frame(minHeight: minimumHitTargetSide)
        .padding(.top, 2)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(.token(.bg))
    }
}

extension TopLevelHeader where Actions == EmptyView {
    public init(_ title: Text) {
        self.init(title) { EmptyView() }
    }
}

extension View {
    /// 作为顶层页：隐去系统导航栏，顶上是自绘的大字标题与行内动作。
    public func topLevelHeader(_ title: Text, @ViewBuilder actions: () -> some View) -> some View {
        let header = TopLevelHeader(title, actions: actions)
        return toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    public func topLevelHeader(_ title: Text) -> some View {
        topLevelHeader(title) { EmptyView() }
    }
}

// MARK: 二级页导航栏

/// 二级页的紧凑导航栏：左侧 `primary` 色返回箭头，中间标题区（可带头像与副标题），右侧动作，底边一条 `line`。
/// 系统导航栏隐去，但页面仍在系统的导航栈里：边缘右滑返回照常可用。
public struct CompactNavigationBar<Leading: View, Trailing: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let onBack: (() -> Void)?
    private let leading: Leading
    private let trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - onBack: 返回做什么；缺省为退回导航栈的上一屏。
    ///   - leading: 标题左边的头像字形等。
    public init(
        title: Text, subtitle: Text? = nil, onBack: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 9) {
            Button {
                if let onBack { onBack() } else { dismiss() }
            } label: {
                Image(.chevronLeft)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.token(.primary))
                    .accessibilityHidden(true)
            }
            .hitTarget()
            .accessibilityLabel(Text("shell.back", tableName: "Shell", bundle: .module))
            .accessibilityIdentifier("shell.back")
            // 稿子的返回框 34、左边距 8；命中区补到 44 后往左让出多出的那一半。
            .padding(.leading, -hitOverhang(34))
            leading
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.agentre(FontRole(size: 15, weight: .semibold, relativeTo: .headline)))
                    .foregroundStyle(.token(.ink))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("shell.title")
                if let subtitle {
                    subtitle
                        .font(.agentre(.caption))
                        .foregroundStyle(.token(.ink2))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) { trailing }
                .padding(.trailing, -hitOverhang(21))
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(minHeight: 56)
        .background(.token(.bg))
        .overlay(alignment: .bottom) { Rectangle().fill(.token(.line)).frame(height: 1) }
    }
}

extension CompactNavigationBar where Leading == EmptyView {
    public init(title: Text, subtitle: Text? = nil, onBack: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, onBack: onBack, leading: { EmptyView() }, trailing: trailing)
    }
}

extension CompactNavigationBar where Leading == EmptyView, Trailing == EmptyView {
    public init(title: Text, subtitle: Text? = nil, onBack: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, onBack: onBack, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

extension View {
    /// 作为二级页：隐去系统导航栏，顶上是紧凑导航栏；返回退回导航栈的上一屏。
    public func compactNavigationBar(
        title: Text, subtitle: Text? = nil,
        @ViewBuilder leading: () -> some View = { EmptyView() }, @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        let bar = CompactNavigationBar(title: title, subtitle: subtitle, leading: leading, trailing: trailing)
        return toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { bar }
            .background(EdgeSwipeBack())
    }
}

/// 系统导航栏一隐去，UIKit 就不再让边缘右滑返回开始（它的手势代理见栏隐藏即拒绝）。
/// 这里把所在导航控制器那枚手势的代理换成只问「栈里是否还有上一屏」的一个，返回手势照常可用。
private struct EdgeSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) {}

    final class Probe: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            // 只为找到所在的导航控制器而在，不接触摸。
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigation = navigationController, let gesture = navigation.interactivePopGestureRecognizer else { return }
            gesture.delegate = PopGestureDelegate.attached(to: navigation)
            gesture.isEnabled = true
        }
    }
}

/// 挂在导航控制器上（手势的代理是弱引用，由关联对象持有）。
@MainActor
private final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    private static var key: UInt8 = 0

    private init(_ navigation: UINavigationController) {
        self.navigation = navigation
    }

    static func attached(to navigation: UINavigationController) -> PopGestureDelegate {
        if let existing = objc_getAssociatedObject(navigation, &key) as? PopGestureDelegate { return existing }
        let delegate = PopGestureDelegate(navigation)
        objc_setAssociatedObject(navigation, &key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return delegate
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let navigation else { return false }
        // 根屏没有上一屏可回；上一次转场还没走完时也不开始新的。
        return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
    }
}

// MARK: 模态导航栏

/// 模态（新建对话）里的导航栏：标题居中，底边一条 `line`。根屏左上是「取消」；模态内推入的一屏左上是
/// 返回箭头连同写着回到哪的文字（「< 新建对话」，规格「05B」），两者是同一个去处、同一个命中区。
public struct ModalNavigationBar: View {
    private let title: Text
    private let backTitle: Text?
    private let onCancel: () -> Void

    public init(title: Text, onCancel: @escaping () -> Void) {
        self.title = title
        self.backTitle = nil
        self.onCancel = onCancel
    }

    /// 模态内推入的一屏：左上「< backTitle」，点了做 `onBack`。
    public init(title: Text, backTitle: Text, onBack: @escaping () -> Void) {
        self.title = title
        self.backTitle = backTitle
        self.onCancel = onBack
    }

    public var body: some View {
        ZStack {
            title
                .font(.agentre(FontRole(size: 16, weight: .semibold, relativeTo: .headline)))
                .foregroundStyle(.token(.ink))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("shell.title")
                // 两侧给「取消」留位，长标题不压到它。
                .padding(.horizontal, 72)
            HStack {
                if let backTitle {
                    Button(action: onCancel) {
                        HStack(spacing: 2) {
                            Image(.chevronLeft)
                                .resizable()
                                .frame(width: 22, height: 22)
                                .accessibilityHidden(true)
                            backTitle
                                .font(.agentre(.body))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.token(.primary))
                    }
                    .hitTarget()
                    .accessibilityIdentifier("shell.back")
                    .padding(.leading, -8)
                } else {
                    Button(action: onCancel) {
                        Text("shell.cancel", tableName: "Shell", bundle: .module)
                            .font(.agentre(.body))
                            .foregroundStyle(.token(.primary))
                    }
                    .hitTarget()
                    .accessibilityIdentifier("shell.cancel")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
        .background(.token(.bg))
        .overlay(alignment: .bottom) { Rectangle().fill(.token(.line)).frame(height: 1) }
    }
}

extension View {
    /// 作为模态的根屏：隐去系统导航栏，顶上是「取消」与居中的标题。
    public func modalNavigationBar(title: Text, onCancel: @escaping () -> Void) -> some View {
        toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { ModalNavigationBar(title: title, onCancel: onCancel) }
    }

    /// 作为模态内推入的一屏：隐去系统导航栏，顶上是「< backTitle」与居中的标题；边缘右滑返回照常可用。
    public func modalNavigationBar(title: Text, backTitle: Text, onBack: @escaping () -> Void) -> some View {
        toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { ModalNavigationBar(title: title, backTitle: backTitle, onBack: onBack) }
            .background(EdgeSwipeBack())
    }
}
