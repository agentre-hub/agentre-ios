import AgentreDesign
import SwiftUI
import UIKit

/// 稿子的搜索框：`surface-2` 底、圆角 11、左侧 `ink-3` 放大镜，绘制高 38，可点区域补到 44。
///
/// 用 UIKit 文本框而不是 SwiftUI 的 `TextField`：后者背后的文本框只有一行字高、命中区改不大（与各屏
/// 原有的搜索框同一个原因）。占位按视图环境的语言解析，在「我」里切语言即换。
public struct SearchField: View {
    @Binding private var text: String
    private let placeholder: LocalizedCopy
    private let onSubmit: () -> Void

    /// - Parameters:
    ///   - placeholder: 占位文案在 `table`（功能目录名）里的键。
    ///   - onSubmit: 按了键盘上的搜索键。
    public init(text: Binding<String>, placeholder: String.LocalizationValue, table: String, onSubmit: @escaping () -> Void = {}) {
        _text = text
        self.placeholder = LocalizedCopy(placeholder, table: table)
        self.onSubmit = onSubmit
    }

    public var body: some View {
        SearchTextField(text: $text, placeholder: placeholder, onSubmit: onSubmit)
            .background {
                RoundedRectangle(cornerRadius: 11)
                    .fill(.token(.surface2))
                    .frame(height: 38)
            }
    }
}

private struct SearchTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: LocalizedCopy
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = UIFont.agentre(FontRole(size: 14.5, relativeTo: .body))
        field.adjustsFontForContentSizeCategory = true
        field.textColor = ColorToken.ink.uiColor
        field.tintColor = ColorToken.primary.uiColor
        field.backgroundColor = .clear
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        let icon = UIImageView(image: UIImage(.search)?.withRenderingMode(.alwaysTemplate))
        icon.tintColor = ColorToken.ink3.uiColor
        icon.contentMode = .scaleAspectFit
        // 放大镜 16pt，左边距 10、与文字间距 7。
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: 33, height: 16))
        icon.frame = CGRect(x: 10, y: 0, width: 16, height: 16)
        holder.addSubview(icon)
        field.leftView = holder
        field.leftViewMode = .always
        field.showPlaceholder(placeholder, in: context.environment.locale)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.showPlaceholder(placeholder, in: context.environment.locale)
        if field.text != text { field.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? field.intrinsicContentSize.width, height: max(minimumHitTargetSide, field.intrinsicContentSize.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchTextField

        init(parent: SearchTextField) {
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
