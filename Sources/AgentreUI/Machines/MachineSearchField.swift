import AgentreDesign
import SwiftUI
import UIKit

/// 按标题搜索的输入框。系统搜索栏的文本框只有 28pt 高、改不了命中区（与 Login 的 AddressField
/// 同一个原因），所以用一个自己定高的 UIKit 文本框：至少 44pt 高。
struct MachineSearchField: UIViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = UIFont.preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = ColorToken.textPrimary.uiColor
        field.tintColor = ColorToken.accent.uiColor
        field.backgroundColor = ColorToken.surface.uiColor
        field.layer.cornerRadius = 10
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.clearButtonMode = .never
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.tintColor = ColorToken.textSecondary.uiColor
        icon.contentMode = .center
        icon.frame = CGRect(x: 0, y: 0, width: 36, height: 20)
        field.leftView = icon
        field.leftViewMode = .always
        field.placeholder = String(localized: "machines.detail.search", table: "Machines", bundle: .module)
        field.accessibilityLabel = field.placeholder
        field.delegate = context.coordinator
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
        CGSize(
            width: proposal.width ?? field.intrinsicContentSize.width,
            height: max(minimumHitTargetSide, field.intrinsicContentSize.height)
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: MachineSearchField

        init(parent: MachineSearchField) {
            self.parent = parent
        }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            parent.onSubmit()
            return false
        }
    }
}
