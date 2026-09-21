import Foundation

/// 界面语言。跟随系统时不覆盖系统的语言选择。
public enum DisplayLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    /// 覆盖界面语言所用的区域标识；跟随系统时为 nil。
    public var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }
}

/// 外观：跟随系统、浅色或深色。
public enum DisplayAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public struct DisplayPreferences: Sendable, Equatable {
    public var language: DisplayLanguage
    public var appearance: DisplayAppearance

    public init(language: DisplayLanguage = .system, appearance: DisplayAppearance = .system) {
        self.language = language
        self.appearance = appearance
    }
}

/// 语言与外观偏好的持久化（不是凭据，不进钥匙串）。
public protocol DisplayPreferencesStore: Sendable {
    func load() -> DisplayPreferences
    func save(_ preferences: DisplayPreferences)
}

/// 偏好存在 UserDefaults；认不出的取值回落到跟随系统。
public struct UserDefaultsDisplayPreferencesStore: DisplayPreferencesStore, @unchecked Sendable {
    public static let languageKey = "displayLanguage"
    public static let appearanceKey = "displayAppearance"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> DisplayPreferences {
        DisplayPreferences(
            language: defaults.string(forKey: Self.languageKey).flatMap(DisplayLanguage.init(rawValue:)) ?? .system,
            appearance: defaults.string(forKey: Self.appearanceKey).flatMap(DisplayAppearance.init(rawValue:)) ?? .system
        )
    }

    public func save(_ preferences: DisplayPreferences) {
        defaults.set(preferences.language.rawValue, forKey: Self.languageKey)
        defaults.set(preferences.appearance.rawValue, forKey: Self.appearanceKey)
    }
}
