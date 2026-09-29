import AgentreDesign
import SwiftUI
import UIKit

/// 输入区的多行文本框：至少 44pt 高（SwiftUI 的 TextField 只有一行字高的命中区），随内容长到
/// 六行左右后在框内滚动。除了文字还报光标位置：斜杠命令与提及按光标前的文本就地触发。
struct ComposerTextField: UIViewRepresentable {
    let text: String
    let cursor: Int
    let placeholder: LocalizedCopy
    let onEdit: (String, Int) -> Void

    private static let maximumHeight: CGFloat = 140

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
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
        guard view.text != text else { return }
        view.text = text
        // 内容由模型改写（选中候选、还回草稿）时，光标跟到模型给的位置。
        let location = min(cursor, (text as NSString).length)
        view.selectedRange = NSRange(location: location, length: 0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        view.isScrollEnabled = fitting > Self.maximumHeight
        return CGSize(width: width, height: min(Self.maximumHeight, max(minimumHitTargetSide, fitting)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextField

        init(parent: ComposerTextField) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            report(view)
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard view.text == parent.text else { return }
            report(view)
        }

        private func report(_ view: UITextView) {
            parent.onEdit(view.text, view.selectedRange.location)
        }
    }
}
