import AgentreDomain
import SwiftUI

/// 语言与外观取值的人话标签：主页的取值列与各自选择页的选项行共用同一份换算。
extension DisplayLanguage {
    var labelKey: LocalizedStringKey {
        switch self {
        case .system: "me.language.system"
        case .simplifiedChinese: "me.language.zhHans"
        case .english: "me.language.en"
        }
    }
}

extension DisplayAppearance {
    var labelKey: LocalizedStringKey {
        switch self {
        case .system: "me.appearance.system"
        case .light: "me.appearance.light"
        case .dark: "me.appearance.dark"
        }
    }
}
