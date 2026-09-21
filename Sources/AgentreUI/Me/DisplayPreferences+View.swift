import AgentreDomain
import SwiftUI

extension DisplayAppearance {
    /// 跟随系统时为 nil：不强加配色方案。
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    /// 施加语言与外观偏好。由应用根视图挂一次，整棵视图树随之切换。
    public func displayPreferences(_ preferences: DisplayPreferences) -> some View {
        transformEnvironment(\.locale) { locale in
            if let identifier = preferences.language.localeIdentifier { locale = Locale(identifier: identifier) }
        }
        .preferredColorScheme(preferences.appearance.colorScheme)
    }
}
