import AgentreDesign
import SwiftUI
import UIKit

/// 三个顶层目的地。
public enum ShellTab: Hashable, CaseIterable, Sendable {
    case messages, machines, me

    /// 界面测试据此找 tab 按钮，不依赖文案与语言。
    var identifier: String {
        switch self {
        case .messages: "shell.tab.messages"
        case .machines: "shell.tab.machines"
        case .me: "shell.tab.me"
        }
    }

    fileprivate var icon: AgentreIcon {
        switch self {
        case .messages: .messageCircle
        case .machines: .server
        case .me: .user
        }
    }

    fileprivate var title: Text {
        switch self {
        case .messages: Text("shell.tab.messages", tableName: "Shell", bundle: .module)
        case .machines: Text("shell.tab.machines", tableName: "Shell", bundle: .module)
        case .me: Text("shell.tab.me", tableName: "Shell", bundle: .module)
        }
    }
}

/// 三个顶层目的地：消息、机器、我，底部是稿子的浮动 tab 栏（决策 23）。各页内容由应用装配层注入。
///
/// tab 栏只在 `showsTabBar`（装配层据导航状态给出：当前页栈空、没有模态）为真且键盘收起时出现；
/// 不出现时它整个不在视图树里，而不是透明或藏在键盘后面。
/// 各页首次选中时才建，建了就一直留着（与系统 TabView 一样）：切回来时导航位置、滚动位置都在。
public struct ShellView<Messages: View, Machines: View, Me: View>: View {
    private let externalSelection: Binding<ShellTab>?
    @State private var ownSelection: ShellTab = .messages
    private let showsTabBar: Bool
    private let messages: Messages
    private let machines: Machines
    private let me: Me
    @State private var mounted: Set<ShellTab> = []
    @State private var keyboardVisible = false
    @State private var bottomSafeArea: CGFloat = 0

    public init(
        selection: Binding<ShellTab>, showsTabBar: Bool,
        @ViewBuilder messages: () -> Messages, @ViewBuilder machines: () -> Machines, @ViewBuilder me: () -> Me
    ) {
        externalSelection = selection
        self.showsTabBar = showsTabBar
        self.messages = messages()
        self.machines = machines()
        self.me = me()
    }

    /// 自己记着选中页、tab 栏只看键盘的外壳（不接导航状态时用，如登录态落地的视图测试）。
    public init(@ViewBuilder messages: () -> Messages, @ViewBuilder machines: () -> Machines, @ViewBuilder me: () -> Me) {
        externalSelection = nil
        showsTabBar = true
        self.messages = messages()
        self.machines = machines()
        self.me = me()
    }

    private var selectionBinding: Binding<ShellTab> { externalSelection ?? $ownSelection }
    private var selection: ShellTab { selectionBinding.wrappedValue }

    public var body: some View {
        ZStack {
            page(.messages) { messages }
            page(.machines) { machines }
            page(.me) { me }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsTabBar, !keyboardVisible {
                FloatingTabBar(selection: selectionBinding)
                    // 稿子里栏底离屏幕下缘 12：伸进主屏指示条那段安全区，而不是停在它上面再空 12。
                    .padding(.bottom, 12 - bottomSafeArea)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottom in
            // 键盘弹起时底部安全区算进了键盘；那时栏不在，只记收起时（主屏指示条）的那一段。
            if !keyboardVisible { bottomSafeArea = bottom }
        }
        .onChange(of: selection, initial: true) { _, tab in mounted.insert(tab) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }

    @ViewBuilder private func page(_ tab: ShellTab, @ViewBuilder content: () -> some View) -> some View {
        if mounted.contains(tab) || selection == tab {
            let selected = selection == tab
            content()
                .opacity(selected ? 1 : 0)
                .allowsHitTesting(selected)
                .accessibilityHidden(!selected)
        }
    }
}

/// 稿子的浮动圆角栏：`glass` 底、描边与柔影，三项线性图标加文字，选中项为 `primary-dim` 胶囊。
struct FloatingTabBar: View {
    @Binding var selection: ShellTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ShellTab.allCases, id: \.self) { tab in
                item(tab)
            }
        }
        .padding(6)
        .frame(height: 58)
        .background(.token(.glass), in: Capsule())
        .overlay(Capsule().strokeBorder(.token(.line)))
        .shadow(color: .token(.shadowSoft), radius: 12, y: 8)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.tabBar")
    }

    private func item(_ tab: ShellTab) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(tab.icon)
                    .resizable()
                    .frame(width: 21, height: 21)
                    .accessibilityHidden(true)
                tab.title
                    .font(.agentre(.caption2, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(.token(selected ? .primary : .ink3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected { RoundedRectangle(cornerRadius: 23).fill(.token(.primaryDim)) }
            }
        }
        .hitTarget()
        .accessibilityIdentifier(tab.identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
