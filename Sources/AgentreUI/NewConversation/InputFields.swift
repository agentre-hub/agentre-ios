import AgentreDesign
import SwiftUI
import UIKit

/// 搜索框。SwiftUI 的 TextField 背后的 UIKit 文本框只有一行字高（实测 22pt），在外面补 frame
/// 撑不大它的命中区；这里让文本框本身至少 44pt 高（与登录屏的地址框同一做法）。
struct NewConversationSearchField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = ColorToken.textPrimary.uiColor
        field.tintColor = ColorToken.accent.uiColor
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .search
        field.clearButtonMode = .never
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        field.accessibilityTraits.insert(.searchField)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? field.intrinsicContentSize.width, height: max(minimumHitTargetSide, field.intrinsicContentSize.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: NewConversationSearchField

        init(parent: NewConversationSearchField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }
    }
}

/// 输入区的多行文本框：至少 44pt 高，随内容长高到六行左右后在框内滚动。
struct NewConversationComposerField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String

    private static let maximumHeight: CGFloat = 140

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = ColorToken.textPrimary.uiColor
        view.tintColor = ColorToken.accent.uiColor
        view.backgroundColor = nil
        view.textContainerInset = UIEdgeInsets(top: 11, left: 8, bottom: 11, right: 8)
        view.accessibilityLabel = placeholder
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        view.isScrollEnabled = fitting > Self.maximumHeight
        return CGSize(width: width, height: min(Self.maximumHeight, max(minimumHitTargetSide, fitting)))
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
