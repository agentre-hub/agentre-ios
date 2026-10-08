import Foundation
import Testing

/// 视图源码（表现层与应用装配层）里不得出现硬编码色值：一切颜色经 `.token(_:)` 取自具名 token。
/// 扫描的是目录而不是名单——后续功能加进 Sources/AgentreUI/<Feature>/ 的视图自动被覆盖。
struct HardCodedColorTests {
    static let repositoryRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let viewSourceDirectories = ["Sources/AgentreUI", "Sources/AgentreApp"]

    @Test("表现层与应用层源码里没有硬编码色值")
    func viewSourcesUseTokensOnly() throws {
        let files = try Self.viewSourceDirectories.flatMap { try swiftFiles(under: Self.repositoryRoot.appending(path: $0)) }
        #expect(files.count >= 3, "扫描范围为空：\(Self.repositoryRoot.path)")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for finding in HardCodedColorScanner.findings(in: source) {
                Issue.record("\(file.lastPathComponent):\(finding.line): \(finding.text)")
            }
        }
    }

    @Test("扫描器认得出各种硬编码写法", arguments: [
        "Text(\"a\").foregroundStyle(Color(red: 1, green: 0, blue: 0))",
        "Text(\"a\").foregroundStyle(Color(white: 0.5))",
        "Text(\"a\").foregroundStyle(Color(hue: 0.5, saturation: 1, brightness: 1))",
        "Text(\"a\").foregroundStyle(Color(.sRGB, red: 1, green: 0, blue: 0))",
        "Text(\"a\").foregroundStyle(Color(\"Brand\"))",
        "Text(\"a\").foregroundStyle(Color.red)",
        "Text(\"a\").foregroundStyle(.blue)",
        "Text(\"a\").tint(.green)",
        "Text(\"a\").foregroundStyle(.secondary)",
        "Text(\"a\").foregroundStyle(.primary)",
        "Text(\"a\").foregroundColor(.primary)",
        "Rectangle().fill(.primary)",
        "Text(\"a\").tint(.primary)",
        "Text(\"a\").foregroundStyle(Color.primary)",
        "Rectangle().fill(Color.black.opacity(0.2))",
        "let c = UIColor(red: 1, green: 0, blue: 0, alpha: 1)",
        "let c = UIColor.systemBlue",
        "let c = #colorLiteral(red: 1, green: 0, blue: 0, alpha: 1)",
        "let hex = \"#1A5CD0\"",
        "let hex: UInt32 = 0x1A5CD0",
    ])
    func scannerCatches(snippet: String) {
        #expect(HardCodedColorScanner.findings(in: snippet).count == 1)
    }

    @Test("token 取色、注释与非颜色的点语法不算违规", arguments: [
        "Text(\"a\").foregroundStyle(.token(.primary))",
        "Rectangle().fill(.token(selected ? .primary : .ink2))",
        "cell(counts.total, \"machines.detail.count.total\", .primary)",
        "case .ok: .primary",
        "let tone: ColorToken = .primary",
        "Rectangle().fill(.token(.surface2))",
        "// 这里不能写 Color.red",
        "/* UIColor(red: 1) */ Text(\"a\")",
        "Text(\"a\").font(.body.monospaced())",
        "Color.clear.frame(width: 1)",
        "let redraw = true; view.blueprint = nil",
    ])
    func scannerAllows(snippet: String) {
        #expect(HardCodedColorScanner.findings(in: snippet).isEmpty)
    }
}

func swiftFiles(under directory: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

enum HardCodedColorScanner {
    struct Finding {
        let line: Int
        let text: String
    }

    private static let namedColors = "red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|white|gray|black|primary|secondary|accentColor"
    /// `primary` 也是 token 名：简写 `.primary` 在取色修饰符的直接参数里才是系统色，别处（`.token(.primary)`、
    /// 返回 ColorToken 的 switch、函数参数）都是 token。
    private static let shorthandColors = namedColors.replacingOccurrences(of: "|primary|", with: "|")
    private static let styleModifiers = "foregroundStyle|foregroundColor|tint|fill|stroke|strokeBorder|background|border|shadow"

    /// 每一条都是一种绕过 token 的取色写法。
    private static var patterns: [NSRegularExpression] { [
        // Color(red:…) / Color(white:) / Color(hue:) / Color(.sRGB, …) / Color("资源名") / Color(uiColor:)
        try! NSRegularExpression(pattern: #"\bColor\s*\(\s*(red|white|hue|uiColor|cgColor|nsColor|\.sRGB|\.displayP3|")"#),
        // Color.red / Color.secondary
        try! NSRegularExpression(pattern: #"\bColor\s*\.\s*(\#(namedColors))\b"#),
        // 简写 .red / .secondary（前面不是标识符或点，排除 view.blueprint 之类）
        try! NSRegularExpression(pattern: #"(?<![\w.])\.(\#(shorthandColors))\b"#),
        // 取色修饰符的直接参数写成 .primary：.foregroundStyle(.primary) / .fill(.primary, …)
        try! NSRegularExpression(pattern: #"\.(\#(styleModifiers))\(\s*\.primary\b"#),
        try! NSRegularExpression(pattern: #"\b(UIColor|CGColor|NSColor)\b"#),
        try! NSRegularExpression(pattern: #"#colorLiteral"#),
        // 十六进制色值："#1A5CD0" 或 0x1A5CD0
        try! NSRegularExpression(pattern: #"(#|\b0x)[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?\b"#),
    ] }

    static func findings(in source: String) -> [Finding] {
        let patterns = patterns
        return stripComments(source).split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            return patterns.contains { $0.firstMatch(in: text, range: range) != nil } ? Finding(line: index + 1, text: line.trimmingCharacters(in: .whitespaces)) : nil
        }
    }

    /// 去掉 // 行注释与 /* */ 块注释（保留换行，行号不变）。字符串里的 // 不在考虑内：视图源码里的 URL 不带颜色。
    private static func stripComments(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") { inBlock = false; index = source.index(index, offsetBy: 2); continue }
                if source[index] == "\n" { output.append("\n") }
            } else if rest.hasPrefix("/*") {
                inBlock = true; index = source.index(index, offsetBy: 2); continue
            } else if rest.hasPrefix("//") {
                index = rest.firstIndex(of: "\n") ?? source.endIndex
                continue
            } else {
                output.append(source[index])
            }
            index = source.index(after: index)
        }
        return output
    }
}
