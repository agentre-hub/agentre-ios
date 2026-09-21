import AgentreDesign
import SwiftUI
import Testing
import UIKit

struct ColorTokenTests {
    static let backgrounds: [ColorToken] = [.bg, .surface, .surface2]

    @Test("每个前景 token 在同主题的 bg / surface / surface-2 上都过对比度阈值（文本 4.5，指示色 3.0）",
          arguments: Theme.allCases)
    func foregroundContrast(theme: Theme) {
        for token in ColorToken.allCases {
            guard case let .foreground(minimum, on) = token.role else { continue }
            for background in on {
                let ratio = contrastRatio(token.rgb(in: theme), background.rgb(in: theme))
                #expect(ratio >= minimum, "\(token) on \(background) in \(theme): \(ratio) < \(minimum)")
            }
        }
    }

    @Test("常规前景 token 都以三层底色为对照；每个 token 都有角色，底色 token 恰是 bg / surface / surface-2")
    func rolesCoverAllLayers() {
        let backgroundTokens = ColorToken.allCases.filter { $0.role == .background }
        #expect(backgroundTokens == Self.backgrounds)
        for token in [ColorToken.textPrimary, .textSecondary, .accent] {
            #expect(token.role == .foreground(minimumContrast: 4.5, on: Self.backgrounds))
        }
        for token in [ColorToken.running, .waiting, .failure] {
            #expect(token.role == .foreground(minimumContrast: 3.0, on: Self.backgrounds))
        }
        #expect(ColorToken.onAccent.role == .foreground(minimumContrast: 4.5, on: [.accent]))
    }

    @Test("深浅两套取值齐全且确实不同：同一 token 的 SwiftUI 颜色随界面风格解析成各自那套")
    func bothThemesResolve() {
        for token in ColorToken.allCases {
            #expect(token.themed.light != token.themed.dark, "\(token) 的深浅取值相同")
            for (theme, style) in [(Theme.light, UIUserInterfaceStyle.light), (.dark, .dark)] {
                let resolved = UIColor(Color.token(token)).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                #expect(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                let expected = token.rgb(in: theme)
                #expect(UInt8((red * 255).rounded()) == expected.red, "\(token) \(theme)")
                #expect(UInt8((green * 255).rounded()) == expected.green, "\(token) \(theme)")
                #expect(UInt8((blue * 255).rounded()) == expected.blue, "\(token) \(theme)")
            }
        }
    }

    @Test("对比度公式本身：黑白 21:1，同色 1:1")
    func contrastFormula() {
        #expect(abs(contrastRatio(RGB(0x000000), RGB(0xFFFFFF)) - 21) < 0.01)
        #expect(abs(contrastRatio(RGB(0x777777), RGB(0x777777)) - 1) < 0.0001)
        #expect(abs(contrastRatio(RGB(0x767676), RGB(0xFFFFFF)) - 4.54) < 0.01)
    }
}
