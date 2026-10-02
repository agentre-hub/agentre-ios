import Foundation
import Testing

/// 视图源码（表现层与应用装配层）里不得绕过随包字体：系统文本样式、系统等宽、系统字重修饰都会落回
/// SF / SF Mono（规格「设计语言」：两者都随 App 打包，不依赖系统字体）。一切取字经 `.agentre(_:mono:weight:)`。
/// 扫描的是目录而不是名单，与 `HardCodedColorTests` 同一范围。
struct SystemFontTests {
    @Test("表现层与应用层源码里不取系统字体")
    func viewSourcesUseBundledFontsOnly() throws {
        let files = try HardCodedColorTests.viewSourceDirectories.flatMap {
            try swiftFiles(under: HardCodedColorTests.repositoryRoot.appending(path: $0))
        }
        #expect(files.count >= 3, "扫描范围为空：\(HardCodedColorTests.repositoryRoot.path)")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for finding in SystemFontScanner.findings(in: source) {
                Issue.record("\(file.lastPathComponent):\(finding.line): \(finding.text)")
            }
        }
    }

    @Test("扫描器认得出各种取系统字的写法", arguments: [
        "Text(\"a\").font(.body)",
        "Text(\"a\").font(.caption.monospaced())",
        "Text(\"a\").font(.subheadline.weight(.semibold))",
        "Text(\"a\").font(.largeTitle)",
        "Text(\"a\").font(.system(size: 12))",
        "Text(\"a\").font(Font.system(.body))",
        "Text(verbatim: id).monospaced()",
        "Text(\"a\").fontWeight(.semibold)",
        "Text(\"a\").bold()",
        "view.font = .preferredFont(forTextStyle: .body)",
        "field.font = UIFont.preferredFont(forTextStyle: .body)",
        "label.font = UIFont.systemFont(ofSize: 12)",
        "label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)",
    ])
    func scannerCatches(snippet: String) {
        #expect(SystemFontScanner.findings(in: snippet).count == 1)
    }

    @Test("随包取字、数字等宽与注释不算违规", arguments: [
        "Text(\"a\").font(.agentre(.body))",
        "Text(\"a\").font(.agentre(.caption, mono: true, weight: .semibold))",
        "field.font = UIFont.agentre(.body)",
        "Text(\"42\").font(.agentre(.title)).monospacedDigit()",
        "// 这里不能写 .font(.body)",
        "static let body = FontRole(size: 15, relativeTo: .body)",
    ])
    func scannerAllows(snippet: String) {
        #expect(SystemFontScanner.findings(in: snippet).isEmpty)
    }
}

enum SystemFontScanner {
    private static let textStyles = "largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2"

    /// 每一条都是一种绕过随包字体的写法。`.monospacedDigit()` 不在其列：它只换数字字形，Inter 自带等宽数字。
    private static var patterns: [NSRegularExpression] { [
        // .font(.body) / .font(.caption.monospaced()) / .font(.system(…))
        try! NSRegularExpression(pattern: #"\.font\(\s*\.(\#(textStyles)|system)\b"#),
        try! NSRegularExpression(pattern: #"\bFont\s*\.\s*(system|\#(textStyles))\b"#),
        // Text.monospaced()：自定义字体没有等宽变体，落回 SF Mono
        try! NSRegularExpression(pattern: #"\.monospaced\(\)"#),
        // 字重修饰：随包字面按角色取字重，修饰会合成或落回系统字
        try! NSRegularExpression(pattern: #"\.fontWeight\("#),
        try! NSRegularExpression(pattern: #"\.bold\(\)"#),
        // UIKit 的系统字
        try! NSRegularExpression(pattern: #"\b(preferredFont|systemFont|monospacedSystemFont|boldSystemFont|italicSystemFont)\s*\("#),
    ] }

    static func findings(in source: String) -> [HardCodedColorScanner.Finding] {
        let patterns = patterns
        return stripLineComments(source).split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
                ? HardCodedColorScanner.Finding(line: index + 1, text: line.trimmingCharacters(in: .whitespaces)) : nil
        }
    }

    /// 去掉 // 行注释（保留换行，行号不变）。
    private static func stripLineComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let range = line.range(of: "//") else { return String(line) }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
    }
}
