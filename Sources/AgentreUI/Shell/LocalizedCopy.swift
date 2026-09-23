import Foundation
import UIKit

/// 一句界面文案的键与所在的表，按给定语言解析成字符串。
///
/// 交给 UIKit 去画、去报的文字（导航栏标题、UIKit 文本框的占位与读屏标签、先排成字符串的候选说明）只能是字符串。
/// `String(localized:table:bundle:)` 按进程的系统语言查表，不看「我」里选的语言（SwiftUI 的 `\.locale`）；
/// 这里按调用方给的 `locale` 查，语言一变解析结果就变。
struct LocalizedCopy: Sendable {
    let key: String.LocalizationValue
    let table: String

    init(_ key: String.LocalizationValue, table: String) {
        self.key = key
        self.table = table
    }

    func resolved(in locale: Locale) -> String {
        var resource = LocalizedStringResource(key, table: table, bundle: .atURL(Bundle.module.bundleURL))
        resource.locale = locale
        return String(localized: resource)
    }
}

extension UIView {
    /// UIKit 文本框的占位（UITextField）与读屏标签按视图环境此刻的语言设。在 make 与 update 里都调：
    /// 在「我」里切换语言时，已建好的文本框随之换成新语言。
    func showPlaceholder(_ copy: LocalizedCopy, in locale: Locale) {
        let text = copy.resolved(in: locale)
        if let field = self as? UITextField, field.placeholder != text { field.placeholder = text }
        if accessibilityLabel != text { accessibilityLabel = text }
    }
}
