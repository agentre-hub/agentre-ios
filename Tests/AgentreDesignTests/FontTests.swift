import AgentreDesign
import SwiftUI
import Testing
import UIKit

struct FontTests {
    @Test("取字即注册：六个随包字重在运行时都能按 PostScript 名解析，解析不到即失败而不是退回系统字体", arguments: [
        "Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold", "JetBrainsMono-Regular", "JetBrainsMono-SemiBold",
    ])
    func bundledFacesResolveByName(name: String) throws {
        _ = UIFont.agentre(.body)
        let font = try #require(UIFont(name: name, size: 15), "\(name) 没注册上")
        #expect(font.fontName == name)
    }

    @Test("角色 × 等宽 × 字重落到对应字面；JetBrains Mono 只随包 400/600，其余就近取", arguments: [
        (FontRole.body, false, FontWeight?.none, "Inter-Regular"),
        (.body, false, .medium, "Inter-Medium"),
        (.body, false, .semibold, "Inter-SemiBold"),
        (.headline, false, nil, "Inter-SemiBold"),
        (.display, false, nil, "Inter-Bold"),
        (.body, true, nil, "JetBrainsMono-Regular"),
        (.body, true, .medium, "JetBrainsMono-Regular"),
        (.body, true, .semibold, "JetBrainsMono-SemiBold"),
        (.body, true, .bold, "JetBrainsMono-SemiBold"),
        (.headline, true, nil, "JetBrainsMono-SemiBold"),
    ])
    func faceForRole(role: FontRole, mono: Bool, weight: FontWeight?, expected: String) {
        let font = UIFont.agentre(role, mono: mono, weight: weight, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        #expect(font.fontName == expected)
        #expect(font.familyName == (mono ? "JetBrains Mono" : "Inter"))
        #expect(font.pointSize == role.size)
    }

    @Test("系统字号放大时随包字体跟着放大，字面不变")
    func dynamicTypeScales() {
        let base = UIFont.agentre(.body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let huge = UIFont.agentre(.body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        let small = UIFont.agentre(.body, mono: true, compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraSmall))
        #expect(base.pointSize == 15)
        #expect(huge.pointSize > base.pointSize * 1.5)
        #expect(huge.fontName == "Inter-Regular")
        #expect(small.pointSize < 15)
        #expect(small.fontName == "JetBrainsMono-Regular")
    }

    @Test("SwiftUI 取字与 UIKit 同名同字号，并以角色的文本样式为基准随系统字号缩放")
    func swiftUIFontMatches() {
        #expect(Font.agentre(.body) == Font.custom("Inter-Regular", size: 15, relativeTo: .body))
        #expect(Font.agentre(.caption, mono: true, weight: .semibold) == Font.custom("JetBrainsMono-SemiBold", size: FontRole.caption.size, relativeTo: FontRole.caption.textStyle))
        #expect(Font.agentre(.body) != Font.custom("Inter-Medium", size: 15, relativeTo: .body))
    }
}
