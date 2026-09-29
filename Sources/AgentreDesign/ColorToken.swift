import SwiftUI
import UIKit

/// 界面上可用的全部颜色。视图只能经 `.token(_:)` 取色：引用一个不存在的 token
/// 是编译错误，而不是静默落到某个兜底色。
///
/// 名字与取值就是 agentre-mobile.pen 的变量（`surface-2` → `surface2`）；身份色取自宿主。
public enum ColorToken: CaseIterable, Sendable {
    case bg
    case surface
    case surface2
    /// 分隔线与描边。
    case line
    case lineStrong
    /// 正文、次级、三级文字。
    case ink
    case ink2
    case ink3
    /// 空闲：只画状态点。
    case idle
    /// 可交互与品牌。
    case primary
    /// 画在 primary 底上的文字与图标。
    case primaryInk
    case primaryDim
    /// 运行中。
    case run
    case runDim
    /// 等你处理。
    case amber
    case amberDim
    /// 失败。
    case coral
    case coralDim
    /// 上下文用量的三档。
    case ctxOk
    case ctxWarn
    case ctxDanger
    /// 带透明度：浮层玻璃、遮罩、投影。
    case glass
    case scrim
    case shadow
    case shadowSoft
    /// 项目与 Agent 的身份色，只出现在头像字形上（宿主 agent-1…agent-16 与 agent-neutral）。
    case agent1, agent2, agent3, agent4, agent5, agent6, agent7, agent8
    case agent9, agent10, agent11, agent12, agent13, agent14, agent15, agent16
    case agentNeutral
    /// 画在身份色上的字形：深浅一律白色。
    case agentInk
}

/// 一个 sRGB 色值，带透明度。
public struct RGB: Sendable, Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    /// 不透明色：0xRRGGBB。
    public init(_ hex: UInt32) {
        self.init(rgba: hex << 8 | 0xFF)
    }

    /// 带透明度：0xRRGGBBAA，与稿子的 `#RRGGBBAA` 同序。
    public init(rgba: UInt32) {
        red = UInt8((rgba >> 24) & 0xFF)
        green = UInt8((rgba >> 16) & 0xFF)
        blue = UInt8((rgba >> 8) & 0xFF)
        alpha = UInt8(rgba & 0xFF)
    }
}

/// 一个 token 的深浅两套取值。两者都是非可选的存储属性：少一套就写不出这个值。
public struct ThemedColor: Sendable, Equatable {
    public let light: RGB
    public let dark: RGB

    /// 不透明色：0xRRGGBB。
    public init(light: UInt32, dark: UInt32) {
        self.light = RGB(light)
        self.dark = RGB(dark)
    }

    /// 带透明度：0xRRGGBBAA。
    public init(lightRGBA: UInt32, darkRGBA: UInt32) {
        light = RGB(rgba: lightRGBA)
        dark = RGB(rgba: darkRGBA)
    }
}

public enum Theme: CaseIterable, Sendable {
    case light
    case dark
}

extension ColorToken {
    /// 取值表。switch 穷举：新增 token 而不给取值是编译错误。
    ///
    /// 稿子原值照抄，只有六处为过对比度线微调（每通道不超过 9/255）：深色 ink3 `#7B8291`、
    /// primaryDim `#1A2738`；浅色 ink3 `#6B707A`、amber 与 ctxWarn `#8F5D08`、run `#0B7A55`。
    public var themed: ThemedColor {
        switch self {
        case .bg: ThemedColor(light: 0xEFF0F3, dark: 0x0C0D10)
        case .surface: ThemedColor(light: 0xFFFFFF, dark: 0x15171C)
        case .surface2: ThemedColor(light: 0xE3E5EA, dark: 0x1D2026)
        case .line: ThemedColor(light: 0xDEE0E5, dark: 0x24272F)
        case .lineStrong: ThemedColor(light: 0xC7CAD1, dark: 0x343843)
        case .ink: ThemedColor(light: 0x18181B, dark: 0xECEEF2)
        case .ink2: ThemedColor(light: 0x5F6470, dark: 0x9BA1AE)
        case .ink3: ThemedColor(light: 0x626771, dark: 0x808796)
        case .idle: ThemedColor(light: 0x787C85, dark: 0x6E7484)
        case .primary: ThemedColor(light: 0x3B6896, dark: 0x5B8DBF)
        case .primaryInk: ThemedColor(light: 0xFFFFFF, dark: 0x0A1420)
        case .primaryDim: ThemedColor(light: 0xEEF4FA, dark: 0x162334)
        case .run: ThemedColor(light: 0x067550, dark: 0x34D399)
        case .runDim: ThemedColor(light: 0xECFDF5, dark: 0x0F2218)
        case .amber: ThemedColor(light: 0x8E5C07, dark: 0xFBBF24)
        case .amberDim: ThemedColor(light: 0xFDFAED, dark: 0x261D0D)
        case .coral: ThemedColor(light: 0xC81E1E, dark: 0xF87171)
        case .coralDim: ThemedColor(light: 0xFEF2F2, dark: 0x2C1512)
        case .ctxOk: ThemedColor(light: 0x3B6896, dark: 0x8EB6DC)
        case .ctxWarn: ThemedColor(light: 0x8E5C07, dark: 0xFBBF24)
        case .ctxDanger: ThemedColor(light: 0xC81E1E, dark: 0xF87171)
        case .glass: ThemedColor(lightRGBA: 0xFFFFFFE6, darkRGBA: 0x15171CE6)
        case .scrim: ThemedColor(lightRGBA: 0x0F172A66, darkRGBA: 0x05060899)
        case .shadow: ThemedColor(lightRGBA: 0x0F172A2E, darkRGBA: 0x00000099)
        case .shadowSoft: ThemedColor(lightRGBA: 0x0F172A1F, darkRGBA: 0x00000066)
        // 宿主 agentre-ui/styles/tokens.css 的 --agent-*（浅 :root，深 .dark）。
        case .agent1: ThemedColor(light: 0x2964E7, dark: 0x1972E0)
        case .agent2: ThemedColor(light: 0x7D3EE9, dark: 0x7E59ED)
        case .agent3: ThemedColor(light: 0x147CB3, dark: 0x137DAD)
        case .agent4: ThemedColor(light: 0xE11D48, dark: 0xE51937)
        case .agent5: ThemedColor(light: 0xAB6413, dark: 0x946F10)
        case .agent6: ThemedColor(light: 0x117D97, dark: 0x108091)
        case .agent7: ThemedColor(light: 0xC026D3, dark: 0xC419DE)
        case .agent8: ThemedColor(light: 0x507E0E, dark: 0x568110)
        case .agent9: ThemedColor(light: 0x4F46E5, dark: 0x5866EC)
        case .agent10: ThemedColor(light: 0xC15015, dark: 0xAE6213)
        case .agent11: ThemedColor(light: 0x0E825F, dark: 0x1D845F)
        case .agent12: ThemedColor(light: 0x0E8076, dark: 0x1B8376)
        case .agent13: ThemedColor(light: 0xD92474, dark: 0xDE1980)
        case .agent14: ThemedColor(light: 0x996D11, dark: 0x88740F)
        case .agent15: ThemedColor(light: 0x64748B, dark: 0x617693)
        case .agent16: ThemedColor(light: 0x9334E9, dark: 0x9A4AEB)
        case .agentNeutral: ThemedColor(light: 0x525252, dark: 0x737373)
        case .agentInk: ThemedColor(light: 0xFFFFFF, dark: 0xFFFFFF)
        }
    }

    public func rgb(in theme: Theme) -> RGB {
        switch theme {
        case .light: themed.light
        case .dark: themed.dark
        }
    }
}

/// token 的用途，决定它要过的对比度线。
public enum TokenRole: Sendable, Equatable {
    /// 三层底色 bg / surface / surface-2。
    case background
    /// 色块与分隔线：自身不过线，画在上面的前景在自己的 `on` 里点它的名。
    case fill
    /// 带透明度的浮层、遮罩与投影：叠在什么上面由界面决定，不算对比度。
    case translucent
    /// 前景：在 `on` 列出的每一层底色上对比度都不低于 `minimumContrast`。
    case foreground(minimumContrast: Double, on: [ColorToken])
}

extension ColorToken {
    private static let layers: [ColorToken] = [.bg, .surface, .surface2]
    private static let identities: [ColorToken] = [
        .agent1, .agent2, .agent3, .agent4, .agent5, .agent6, .agent7, .agent8,
        .agent9, .agent10, .agent11, .agent12, .agent13, .agent14, .agent15, .agent16, .agentNeutral,
    ]

    public var role: TokenRole {
        switch self {
        case .bg, .surface, .surface2: .background
        case .line, .lineStrong, .primaryDim, .runDim, .amberDim, .coralDim: .fill
        case .agent1, .agent2, .agent3, .agent4, .agent5, .agent6, .agent7, .agent8,
             .agent9, .agent10, .agent11, .agent12, .agent13, .agent14, .agent15, .agent16, .agentNeutral: .fill
        case .glass, .scrim, .shadow, .shadowSoft: .translucent
        // 上下文百分比随环的档位着色：按文字线算。
        case .ink, .ink2, .ink3, .ctxOk, .ctxWarn, .ctxDanger: .foreground(minimumContrast: 4.5, on: Self.layers)
        // 状态色也写成文字，且写在自己的 -dim 胶囊上（选中 tab 的字写在 primary-dim 上）。
        case .primary: .foreground(minimumContrast: 4.5, on: Self.layers + [.primaryDim])
        case .run: .foreground(minimumContrast: 4.5, on: Self.layers + [.runDim])
        case .amber: .foreground(minimumContrast: 4.5, on: Self.layers + [.amberDim])
        case .coral: .foreground(minimumContrast: 4.5, on: Self.layers + [.coralDim])
        // 只画状态点，按指示色的线算。
        case .idle: .foreground(minimumContrast: 3.0, on: Self.layers)
        case .primaryInk: .foreground(minimumContrast: 4.5, on: [.primary])
        case .agentInk: .foreground(minimumContrast: 4.5, on: Self.identities)
        }
    }
}

/// WCAG 2.x 对比度：(L1 + 0.05) / (L2 + 0.05)，L 为相对亮度。只对不透明色有意义，透明度不参与。
public func contrastRatio(_ first: RGB, _ second: RGB) -> Double {
    let (lighter, darker) = (max(first.luminance, second.luminance), min(first.luminance, second.luminance))
    return (lighter + 0.05) / (darker + 0.05)
}

extension RGB {
    var luminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
    }
}

extension ColorToken {
    /// 给 UIKit 视图用的同一个 token：随界面风格在深浅两套取值间切换。
    public var uiColor: UIColor {
        let themed = themed
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? themed.dark.uiColor : themed.light.uiColor
        }
    }
}

extension ShapeStyle where Self == Color {
    /// 视图取色的唯一入口：随界面风格在深浅两套取值间切换。
    public static func token(_ token: ColorToken) -> Color {
        Color(uiColor: token.uiColor)
    }
}
