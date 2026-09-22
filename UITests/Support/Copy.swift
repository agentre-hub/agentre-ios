import Foundation

/// 界面文案按语言取自 App 自己的字符串目录（project.yml 把 Sources/AgentreUI 下的 .xcstrings
/// 编进本测试包），测试里不另抄一份：文案改了，测试跟着改；键没了，测试当场失败。
struct Copy {
    let language: String
    private let bundle: Bundle

    init(language: String) {
        self.language = language
        let base = Bundle(for: CopyBundleMarker.self)
        guard let path = base.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else {
            fatalError("no \(language).lproj in the UI test bundle: the string catalogs were not compiled into it")
        }
        self.bundle = bundle
    }

    /// `table` 是功能目录名（Login、Machines……），`key` 是目录里的键；带格式的键按参数填上。
    func callAsFunction(_ table: String, _ key: String, _ arguments: CVarArg...) -> String {
        let missing = "\u{0}missing"
        let format = bundle.localizedString(forKey: key, value: missing, table: table)
        precondition(format != missing, "no \(language) copy for \(table)/\(key)")
        return arguments.isEmpty ? format : String(format: format, arguments: arguments)
    }
}

private final class CopyBundleMarker {}
