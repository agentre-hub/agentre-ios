import SwiftUI
import UIKit

/// 界面上可用的全部颜色。视图只能经 `.token(_:)` 取色：引用一个不存在的 token
/// 是编译错误，而不是静默落到某个兜底色。
public enum ColorToken: CaseIterable, Sendable {
    case bg
    case surface
    case surface2
    case textPrimary
    case textSecondary
    /// 可交互与品牌。
    case accent
    /// 画在 accent 底上的文字与图标。
    case onAccent
    /// 运行中。
    case running
    /// 等你处理。
    case waiting
    /// 失败。
    case failure
}

/// 一个 sRGB 色值。
public struct RGB: Sendable, Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(_ hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }
}

/// 一个 token 的深浅两套取值。两者都是非可选的存储属性：少一套就写不出这个值。
public struct ThemedColor: Sendable, Equatable {
    public let light: RGB
    public let dark: RGB

    public init(light: UInt32, dark: UInt32) {
        self.light = RGB(light)
        self.dark = RGB(dark)
    }
}

public enum Theme: CaseIterable, Sendable {
    case light
    case dark
}

extension ColorToken {
    /// 取值表。switch 穷举：新增 token 而不给取值是编译错误。
    public var themed: ThemedColor {
        switch self {
        case .bg: ThemedColor(light: 0xF6F7F9, dark: 0x0E1015)
        case .surface: ThemedColor(light: 0xFFFFFF, dark: 0x171A21)
        case .surface2: ThemedColor(light: 0xECEEF2, dark: 0x21252E)
        case .textPrimary: ThemedColor(light: 0x14171F, dark: 0xF2F4F8)
        case .textSecondary: ThemedColor(light: 0x505869, dark: 0xA6ADBB)
        case .accent: ThemedColor(light: 0x1A5CD0, dark: 0x74A6FF)
        case .onAccent: ThemedColor(light: 0xFFFFFF, dark: 0x0E1015)
        case .running: ThemedColor(light: 0x1E8045, dark: 0x4CC57C)
        case .waiting: ThemedColor(light: 0xA85F00, dark: 0xF0A93B)
        case .failure: ThemedColor(light: 0xC62E2E, dark: 0xFF6E6E)
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
    case background
    /// 前景：在 `on` 列出的每一层底色上对比度都不低于 `minimumContrast`。
    case foreground(minimumContrast: Double, on: [ColorToken])
}

extension ColorToken {
    private static let layers: [ColorToken] = [.bg, .surface, .surface2]

    public var role: TokenRole {
        switch self {
        case .bg, .surface, .surface2: .background
        case .textPrimary, .textSecondary, .accent: .foreground(minimumContrast: 4.5, on: Self.layers)
        case .running, .waiting, .failure: .foreground(minimumContrast: 3.0, on: Self.layers)
        case .onAccent: .foreground(minimumContrast: 4.5, on: [.accent])
        }
    }
}

/// WCAG 2.x 对比度：(L1 + 0.05) / (L2 + 0.05)，L 为相对亮度。
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
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
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
