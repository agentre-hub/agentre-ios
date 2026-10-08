import AgentreDesign
import SwiftUI
import UIKit

/// 输入区的多行文本框：至少 44pt 高，随内容长高到六行左右后在框内滚动。
struct NewConversationComposerField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: LocalizedCopy

    private static let maximumHeight: CGFloat = 140
    /// UIKit 控件的命中区靠窗口逐点量出，紧贴 44 的下限会被量成 43——多留 2pt 富余（与对话屏输入框同一做法）。
    private static let minimumHeight: CGFloat = minimumHitTargetSide + 2

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFont.agentre(FontRole(size: 14.5, relativeTo: .body))
        view.adjustsFontForContentSizeCategory = true
        view.textColor = ColorToken.ink.uiColor
        view.tintColor = ColorToken.primary.uiColor
        view.backgroundColor = nil
        view.textContainerInset = UIEdgeInsets(top: 11, left: 8, bottom: 11, right: 8)
        view.showPlaceholder(placeholder, in: context.environment.locale)
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.showPlaceholder(placeholder, in: context.environment.locale)
        if view.text != text { view.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        view.isScrollEnabled = fitting > Self.maximumHeight
        return CGSize(width: width, height: min(Self.maximumHeight, max(Self.minimumHeight, fitting)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NewConversationComposerField

        init(parent: NewConversationComposerField) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
        }
    }
}

/// 横向滚动的一行（项目胶囊）。用 UIKit 的滚动视图托着一份 SwiftUI 内容，而不是 SwiftUI 的 `ScrollView`：
/// 命中区检查器（AgentreTestSupport，冻结）在 SwiftUI 的 `ScrollView` 里看不到任何元素，托在 UIKit 滚动视图
/// 里的那份内容它照样从视图层级里找得到。那份内容另起一棵 SwiftUI 树，外观、字号与测试登记命中区的收集器
/// 随环境显式传进去。
struct HorizontalScroller<Content: View>: UIViewRepresentable {
    let content: Content
    @Environment(\.hitTargetCollector) private var collector
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.backgroundColor = .clear
        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        host.sizingOptions = [.intrinsicContentSize]
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            host.view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.host.rootView = hosted
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView scroll: UIScrollView, context: Context) -> CGSize? {
        let fitting = context.coordinator.host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        return CGSize(width: proposal.width ?? fitting.width, height: fitting.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(content: hosted) }

    private var hosted: AnyView {
        AnyView(
            content
                .environment(\.hitTargetCollector, collector)
                .environment(\.colorScheme, colorScheme)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        )
    }

    @MainActor
    final class Coordinator {
        let host: UIHostingController<AnyView>

        init(content: AnyView) {
            host = UIHostingController(rootView: content)
        }
    }
}
