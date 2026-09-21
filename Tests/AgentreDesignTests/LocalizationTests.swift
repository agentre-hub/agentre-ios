import AgentreUI
import Foundation
import Testing

/// 字符串目录的守卫。按目录扫描：后续功能在 Sources/AgentreUI/<Feature>/<Feature>.xcstrings
/// 新增的表不改清单、不改本文件即被覆盖。
struct LocalizationTests {
    static let root = HardCodedColorTests.repositoryRoot
    static let languages = ["en", "zh-Hans"]

    static func catalogs() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root.appending(path: "Sources"), includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "xcstrings" }
    }

    @Test("每张表每个条目都有简体中文与英文，且都已翻译、非空")
    func noEntryMissesALanguage() throws {
        let catalogs = try Self.catalogs()
        #expect(catalogs.count >= 2)
        for url in catalogs {
            for problem in try StringCatalog(contentsOf: url).problems(requiring: Self.languages) {
                Issue.record("\(url.lastPathComponent): \(problem)")
            }
        }
    }

    @Test("守卫自身：缺语言、未翻译、空值都被认出")
    func catalogGuardCatchesGaps() throws {
        let json = """
        {"sourceLanguage":"en","version":"1.0","strings":{
          "ok":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"OK"}},"zh-Hans":{"stringUnit":{"state":"translated","value":"好"}}}},
          "missing":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"Missing"}}}},
          "stale":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"A"}},"zh-Hans":{"stringUnit":{"state":"new","value":"甲"}}}},
          "empty":{"localizations":{"en":{"stringUnit":{"state":"translated","value":""}},"zh-Hans":{"stringUnit":{"state":"translated","value":"乙"}}}},
          "bare":{}
        }}
        """
        let problems = try StringCatalog(data: Data(json.utf8)).problems(requiring: Self.languages)
        #expect(problems.count == 5, "\(problems)")
        #expect(!problems.contains { $0.hasPrefix("ok") })
    }

    @Test("每张表都随表现层资源包发布：两种语言下每个键都解析成目录里的译文")
    func tablesShipInTheBundle() throws {
        let bundle = AgentreUIResources.bundle
        let catalogs = try Self.catalogs().filter { $0.path.contains("/Sources/AgentreUI/") }
        #expect(Set(catalogs.map { $0.deletingPathExtension().lastPathComponent }).isSuperset(of: ["Login", "Shell"]))
        for url in catalogs {
            let table = url.deletingPathExtension().lastPathComponent
            let catalog = try StringCatalog(contentsOf: url)
            for language in Self.languages {
                let path = try #require(bundle.path(forResource: language, ofType: "lproj"), "\(language).lproj 不在资源包里")
                let localized = try #require(Bundle(path: path))
                for (key, values) in catalog.values {
                    let resolved = localized.localizedString(forKey: key, value: "⟨missing⟩", table: table)
                    #expect(resolved == values[language], "\(table).\(key) [\(language)]")
                }
            }
        }
    }

    @Test("表现层与应用层源码不以拼接构造句子")
    func noSentenceConcatenation() throws {
        let files = try HardCodedColorTests.viewSourceDirectories.flatMap { try swiftFiles(under: Self.root.appending(path: $0)) }
        for file in files {
            for finding in ConcatenationScanner.findings(in: try String(contentsOf: file, encoding: .utf8)) {
                Issue.record("\(file.lastPathComponent): \(finding)")
            }
        }
    }

    @Test("拼接扫描器认得出各种拼法", arguments: [
        "Text(\"login.a\", bundle: .module) + Text(\"login.b\", bundle: .module)",
        "Text(verbatim: name)\n    + Text(\"login.b\")",
        "let s = String(localized: \"a\") + name",
        "let s = name + String(localized: \"a\")",
        "let s = \"Hello, \" + name",
        "let s = name + \" items\"",
        "let s = NSLocalizedString(\"a\", comment: \"\")",
        "let s = [String(localized: \"a\"), name].joined(separator: \" \")",
    ])
    func concatenationScannerCatches(snippet: String) {
        #expect(!ConcatenationScanner.findings(in: snippet).isEmpty)
    }

    @Test("拼接扫描器不误报", arguments: [
        "Text(\"login.signIn\", tableName: \"Login\", bundle: .module)",
        "let url = base.appending(path: path)",
        "let width = a + b",
        "Text(verbatim: address.url.absoluteString)",
    ])
    func concatenationScannerAllows(snippet: String) {
        #expect(ConcatenationScanner.findings(in: snippet).isEmpty)
    }
}

/// .xcstrings 的最小解析。
struct StringCatalog {
    /// 键 → 语言 → 译文（仅不带变体的条目；带复数等变体的条目只参与缺语言检查）。
    let values: [String: [String: String]]
    private let strings: [String: [String: Any]]

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        strings = object?["strings"] as? [String: [String: Any]] ?? [:]
        values = strings.mapValues { entry in
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            return localizations.compactMapValues { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
        }
    }

    /// 缺某种语言、某个译文单元未标为已翻译、或译文为空，各记一条。
    func problems(requiring languages: [String]) -> [String] {
        strings.keys.sorted().flatMap { key -> [String] in
            let localizations = strings[key]?["localizations"] as? [String: Any] ?? [:]
            return languages.compactMap { language in
                guard let localization = localizations[language] else { return "\(key) 缺 \(language)" }
                let units = Self.stringUnits(in: localization)
                if units.isEmpty { return "\(key) [\(language)] 没有译文" }
                if units.contains(where: { $0["state"] as? String != "translated" }) { return "\(key) [\(language)] 未翻译" }
                if units.contains(where: { ($0["value"] as? String ?? "").isEmpty }) { return "\(key) [\(language)] 为空" }
                return nil
            }
        }
    }

    /// 一个本地化节点下的全部 stringUnit（含复数、设备等变体里的）。
    private static func stringUnits(in node: Any) -> [[String: Any]] {
        guard let dictionary = node as? [String: Any] else { return [] }
        if let unit = dictionary["stringUnit"] as? [String: Any] { return [unit] }
        return dictionary.values.flatMap { stringUnits(in: $0) }
    }
}

/// 以拼接构造句子的写法：Text 相加、本地化串与别的串相加、字符串字面量相加、
/// 把本地化串拼成数组再 joined、以及绕过字符串目录的 NSLocalizedString。
enum ConcatenationScanner {
    private static var patterns: [NSRegularExpression] { [
        try! NSRegularExpression(pattern: #"\)\s*\+\s*Text\s*\("#),
        try! NSRegularExpression(pattern: #"String\(localized:[^\n]*\)\s*\+"#),
        try! NSRegularExpression(pattern: #"\+\s*String\(localized:"#),
        try! NSRegularExpression(pattern: #""\s*\+|\+\s*""#),
        try! NSRegularExpression(pattern: #"\bNSLocalizedString\b"#),
        try! NSRegularExpression(pattern: #"String\(localized:[^\n]*\]\s*\.joined"#),
    ] }

    static func findings(in source: String) -> [String] {
        let range = NSRange(source.startIndex..., in: source)
        return patterns.flatMap { pattern in
            pattern.matches(in: source, range: range).compactMap { match in
                Range(match.range, in: source).map { String(source[$0]) }
            }
        }
    }
}
