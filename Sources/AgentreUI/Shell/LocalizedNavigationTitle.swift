import SwiftUI

extension View {
    /// 按当前 `\.locale` 解析好的导航栏标题。
    ///
    /// 不用 `navigationTitle(Text(key, …))`：本地化的 `Text` 只是键、表、包三样，切换语言前后它是同一个值，
    /// SwiftUI 于是不再把标题推给 UIKit 的导航栏，栏上一直是首次解析出的那种语言（在「我」里切语言后
    /// 标签栏与列表换了，大标题却没换）。这里先按环境语言解析成字符串，语言一变值就变，导航栏随之重设。
    func localizedNavigationTitle(_ key: String.LocalizationValue, table: String) -> some View {
        modifier(LocalizedNavigationTitle(key: key, table: table))
    }
}

private struct LocalizedNavigationTitle: ViewModifier {
    let key: String.LocalizationValue
    let table: String
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        var resource = LocalizedStringResource(key, table: table, bundle: .atURL(Bundle.module.bundleURL))
        resource.locale = locale
        return content.navigationTitle(String(localized: resource))
    }
}
