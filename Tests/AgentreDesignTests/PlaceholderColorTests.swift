import AgentreDesign
@testable import AgentreUI
import Testing
import UIKit

/// UIKit 文本框的占位取 `ink-3`（稿子的搜索框占位就是它，规格「设计语言」那六处偏离之一为它过对比度线），
/// 不落回系统的 placeholderText——那不是具名 token，深浅两套也不是稿子的取值。
@MainActor
struct PlaceholderColorTests {
    @Test("文本框占位是 ink-3，字与文本框同一款随包字体")
    func placeholderUsesInk3() throws {
        let field = UITextField()
        field.font = UIFont.agentre(.body)
        field.showPlaceholder(LocalizedCopy("messages.search", table: "Messages"), in: Locale(identifier: "zh-Hans"))
        let placeholder = try #require(field.attributedPlaceholder)
        #expect(!placeholder.string.isEmpty)
        let color = placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            #expect(color?.resolvedColor(with: traits) == ColorToken.ink3.uiColor.resolvedColor(with: traits), "\(style.rawValue)")
        }
        let font = placeholder.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(font?.fontName == field.font?.fontName)
    }
}
