import Foundation
import Observation
import SwiftUI

/// 视图层测试里的「我」→ 语言：托管视图树的 `\.locale` 由它给，改 `language` 即就地切换
/// ——已建好的 UIKit 视图（文本框的占位与读屏标签）走更新而不是重建，与 App 里切语言时一样。
@MainActor
@Observable
public final class InAppLanguage {
    public var language: String

    public init(_ language: String) {
        self.language = language
    }

    /// 进程按系统语言会从 `bundle` 里挑中的那种语言：`String(localized:)` 不看 App 内的选择，查的就是它。
    public static func system(of bundle: Bundle) -> String {
        bundle.preferredLocalizations.first ?? "en"
    }

    /// 与系统语言不同的另一种：在它下面还读到系统语言的文案，就是没跟 App 内的选择走。
    public static func other(than language: String) -> String {
        language == "en" ? "zh-Hans" : "en"
    }
}

extension View {
    /// 让这棵视图树的语言跟随 `language`。
    public func inAppLanguage(_ language: InAppLanguage) -> some View {
        InAppLanguageRoot(language: language, content: self)
    }
}

private struct InAppLanguageRoot<Content: View>: View {
    let language: InAppLanguage
    let content: Content

    var body: some View {
        content.environment(\.locale, Locale(identifier: language.language))
    }
}

/// 在 App 内先选与系统不同的语言、再切回系统语言，每一步都读屏：`copy` 在该语言下的译文应恰是屏上的一个标签，
/// `partOfLabels` 的译文应是某个标签的一部分（与别的字并在一行读出的，如候选行「/compact, 说明」）；
/// 另一种语言的那句都不应在。返回不符的描述，空即通过。`afterSwitch` 在每次切换后、读屏前调用
/// （例如重新键入一个触发）。
@MainActor
public func inAppLanguageMismatches(
    of view: some View, bundle: Bundle, copy: [(key: String, table: String)], partOfLabels: [(key: String, table: String)] = [],
    afterSwitch: (String) -> Void = { _ in }
) async -> [String] {
    let system = InAppLanguage.system(of: bundle)
    let language = InAppLanguage(InAppLanguage.other(than: system))
    let screen = HostedScreen(view.inAppLanguage(language))
    var mismatches: [String] = []
    for current in [InAppLanguage.other(than: system), system] {
        language.language = current
        afterSwitch(current)
        let labels = await screen.labels() + screen.textInputLabels()
        let checks = copy.map { ($0, whole: true) } + partOfLabels.map { ($0, whole: false) }
        for ((key, table), whole) in checks {
            let shows = { (text: String) in whole ? labels.contains(text) : labels.contains { $0.contains(text) } }
            let expected = localized(key, table: table, language: current, in: bundle)
            let stale = localized(key, table: table, language: InAppLanguage.other(than: current), in: bundle)
            if !shows(expected) { mismatches.append("\(current): “\(expected)” (\(key)) not on screen: \(labels)") }
            if expected != stale, shows(stale) { mismatches.append("\(current): stale “\(stale)” (\(key)) still on screen") }
        }
    }
    return mismatches
}

private func localized(_ key: String, table: String, language: String, in bundle: Bundle) -> String {
    let lproj = bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    return (lproj ?? bundle).localizedString(forKey: key, value: "⟨missing \(language):\(key)⟩", table: table)
}
