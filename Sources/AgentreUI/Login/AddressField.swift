import AgentreDesign
import SwiftUI
import UIKit

/// 服务器地址输入框。SwiftUI 的 TextField 背后那个 UIKit 文本框只有一行字高（实测 22pt），
/// 在外面补 frame 撑不大它的命中区；这里让文本框本身至少 44pt 高。
struct AddressField: UIViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    private static let placeholder = LocalizedCopy("login.server", table: "Login")

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
        field.adjustsFontForContentSizeCategory = true
        field.textColor = ColorToken.textPrimary.uiColor
        field.tintColor = ColorToken.accent.uiColor
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.clearButtonMode = .never
        field.showPlaceholder(Self.placeholder, in: context.environment.locale)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.showPlaceholder(Self.placeholder, in: context.environment.locale)
        if field.text != text { field.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? field.intrinsicContentSize.width,
            height: max(minimumHitTargetSide, field.intrinsicContentSize.height)
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField

        init(parent: AddressField) {
            self.parent = parent
        }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
