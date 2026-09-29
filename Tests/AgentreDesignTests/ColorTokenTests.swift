import AgentreDesign
import SwiftUI
import Testing
import UIKit

struct ColorTokenTests {
    static let backgrounds: [ColorToken] = [.bg, .surface, .surface2]
    static let identities: [ColorToken] = [
        .agent1, .agent2, .agent3, .agent4, .agent5, .agent6, .agent7, .agent8,
        .agent9, .agent10, .agent11, .agent12, .agent13, .agent14, .agent15, .agent16, .agentNeutral,
    ]

    /// agentre-mobile.pen 的变量表原样（pencil `GetVariables()`，2026-09-29 读取），(浅色, 深色)。
    /// 稿子的 `proj-1…5` 与 `on-proj` 不在其中：规格决策 21 改用宿主的身份色。
    static let design: [String: (light: String, dark: String)] = [
        "bg": ("#EFF0F3", "#0C0D10"),
        "surface": ("#FFFFFF", "#15171C"),
        "surface-2": ("#E3E5EA", "#1D2026"),
        "line": ("#DEE0E5", "#24272F"),
        "line-strong": ("#C7CAD1", "#343843"),
        "ink": ("#18181B", "#ECEEF2"),
        "ink-2": ("#5F6470", "#9BA1AE"),
        "ink-3": ("#6B707A", "#7B8291"),
        "idle": ("#787C85", "#6E7484"),
        "primary": ("#3B6896", "#5B8DBF"),
        "primary-ink": ("#FFFFFF", "#0A1420"),
        "primary-dim": ("#EEF4FA", "#1A2738"),
        "run": ("#0B7A55", "#34D399"),
        "run-dim": ("#ECFDF5", "#0F2218"),
        "amber": ("#8F5D08", "#FBBF24"),
        "amber-dim": ("#FDFAED", "#261D0D"),
        "coral": ("#C81E1E", "#F87171"),
        "coral-dim": ("#FEF2F2", "#2C1512"),
        "ctx-ok": ("#3B6896", "#8EB6DC"),
        "ctx-warn": ("#8F5D08", "#FBBF24"),
        "ctx-danger": ("#C81E1E", "#F87171"),
        "glass": ("#FFFFFFE6", "#15171CE6"),
        "scrim": ("#0F172A66", "#05060899"),
        "shadow": ("#0F172A2E", "#00000099"),
        "shadow-soft": ("#0F172A1F", "#00000066"),
    ]

    /// 规格「设计语言」列出的六处、仅有的六处为过对比度线而偏离稿子的取值。
    static let deviations: [String: [Theme: String]] = [
        "ink-3": [.dark: "#808796", .light: "#626771"],
        "primary-dim": [.dark: "#162334"],
        "amber": [.light: "#8E5C07"],
        "ctx-warn": [.light: "#8E5C07"],
        "run": [.light: "#067550"],
    ]

    /// 宿主身份色：agentre-ui/styles/tokens.css:172-191（浅）与 :358-376（深），(浅色, 深色)。
    static let host: [String: (light: String, dark: String)] = [
        "agent-1": ("#2964E7", "#1972E0"),
        "agent-2": ("#7D3EE9", "#7E59ED"),
        "agent-3": ("#147CB3", "#137DAD"),
        "agent-4": ("#E11D48", "#E51937"),
        "agent-5": ("#AB6413", "#946F10"),
        "agent-6": ("#117D97", "#108091"),
        "agent-7": ("#C026D3", "#C419DE"),
        "agent-8": ("#507E0E", "#568110"),
        "agent-9": ("#4F46E5", "#5866EC"),
        "agent-10": ("#C15015", "#AE6213"),
        "agent-11": ("#0E825F", "#1D845F"),
        "agent-12": ("#0E8076", "#1B8376"),
        "agent-13": ("#D92474", "#DE1980"),
        "agent-14": ("#996D11", "#88740F"),
        "agent-15": ("#64748B", "#617693"),
        "agent-16": ("#9334E9", "#9A4AEB"),
        "agent-neutral": ("#525252", "#737373"),
        // --agent-foreground：身份色上的字一律白色。
        "agent-ink": ("#FFFFFF", "#FFFFFF"),
    ]

    @Test("token 恰是稿子的变量（camelCase）加宿主身份色，一个不多一个不少")
    func tokenNamesAreTheDesignVariables() {
        let names = Set(ColorToken.allCases.map(designName))
        #expect(names == Set(Self.design.keys).union(Self.host.keys))
    }

    @Test("取值逐一等于稿子的变量表，只有规格列出的六处偏离", arguments: Theme.allCases)
    func valuesEqualTheDesign(theme: Theme) throws {
        for (name, values) in Self.design {
            let token = try #require(ColorToken.allCases.first { designName($0) == name }, "缺 token \(name)")
            let expected = Self.deviations[name]?[theme] ?? (theme == .light ? values.light : values.dark)
            #expect(token.rgb(in: theme) == rgb(expected), "\(name) \(theme)")
        }
    }

    @Test("六处偏离都真的偏离了稿子，且每通道不超过 9/255")
    func deviationsAreSmall() {
        let count = Self.deviations.values.reduce(0) { $0 + $1.count }
        #expect(count == 6)
        for (name, themes) in Self.deviations {
            for (theme, value) in themes {
                let original = rgb(theme == .light ? Self.design[name]!.light : Self.design[name]!.dark)
                let deviated = rgb(value)
                let channels = [(original.red, deviated.red), (original.green, deviated.green), (original.blue, deviated.blue)]
                #expect(original != deviated, "\(name) \(theme) 并未偏离")
                #expect(channels.allSatisfy { abs(Int($0) - Int($1)) <= 9 }, "\(name) \(theme)")
            }
        }
    }

    @Test("身份色 agent-1…16 与 agent-neutral 取自宿主 tokens.css，字色 agent-ink 深浅都是白", arguments: Theme.allCases)
    func identityColorsEqualTheHost(theme: Theme) throws {
        for (name, values) in Self.host {
            let token = try #require(ColorToken.allCases.first { designName($0) == name }, "缺 token \(name)")
            #expect(token.rgb(in: theme) == rgb(theme == .light ? values.light : values.dark), "\(name) \(theme)")
        }
    }

    @Test("glass / scrim / shadow / shadow-soft 带透明度，经 SwiftUI 取色后透明度保留")
    func translucentTokensKeepAlpha() {
        for token in [ColorToken.glass, .scrim, .shadow, .shadowSoft] {
            #expect(token.role == .translucent)
            for (theme, style) in [(Theme.light, UIUserInterfaceStyle.light), (.dark, .dark)] {
                let expected = token.rgb(in: theme)
                #expect(expected.alpha < 0xFF, "\(token) \(theme) 不透明")
                let resolved = UIColor(Color.token(token)).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                #expect(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                #expect(UInt8((alpha * 255).rounded()) == expected.alpha, "\(token) \(theme)")
            }
        }
        for token in ColorToken.allCases where token.role != .translucent {
            #expect(token.rgb(in: .light).alpha == 0xFF && token.rgb(in: .dark).alpha == 0xFF, "\(token) 不该带透明度")
        }
    }

    @Test("每个前景 token 在自己角色列出的每一层底色上都过对比度阈值，两套主题各自算",
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

    @Test("角色：文字与状态色 4.5 过三层底色，状态色另过自己的 -dim；idle 只画状态点按 3.0；primary-ink 在 primary 上、白字在每个身份色上")
    func roles() {
        let layers = Self.backgrounds
        #expect(ColorToken.allCases.filter { $0.role == .background } == layers)
        for token in [ColorToken.ink, .ink2, .ink3, .ctxOk, .ctxWarn, .ctxDanger] {
            #expect(token.role == .foreground(minimumContrast: 4.5, on: layers), "\(token)")
        }
        #expect(ColorToken.primary.role == .foreground(minimumContrast: 4.5, on: layers + [.primaryDim]))
        #expect(ColorToken.run.role == .foreground(minimumContrast: 4.5, on: layers + [.runDim]))
        #expect(ColorToken.amber.role == .foreground(minimumContrast: 4.5, on: layers + [.amberDim]))
        #expect(ColorToken.coral.role == .foreground(minimumContrast: 4.5, on: layers + [.coralDim]))
        #expect(ColorToken.idle.role == .foreground(minimumContrast: 3.0, on: layers))
        #expect(ColorToken.primaryInk.role == .foreground(minimumContrast: 4.5, on: [.primary]))
        #expect(ColorToken.agentInk.role == .foreground(minimumContrast: 4.5, on: Self.identities))
    }

    @Test("六处偏离确有必要：只把这一处换回稿子原值，就有前景落到线下", arguments: [
        ("ink-3", Theme.dark), ("primary-dim", .dark), ("ink-3", .light), ("amber", .light), ("ctx-warn", .light), ("run", .light),
    ])
    func originalsFailTheLine(name: String, theme: Theme) {
        let original = rgb(theme == .light ? Self.design[name]!.light : Self.design[name]!.dark)
        func value(_ token: ColorToken) -> RGB { designName(token) == name ? original : token.rgb(in: theme) }
        let failing = ColorToken.allCases.contains { token in
            guard case let .foreground(minimum, on) = token.role else { return false }
            return on.contains { contrastRatio(value(token), value($0)) < minimum }
        }
        #expect(failing, "\(name) \(theme) 用稿子原值也过线，这处偏离没有依据")
    }

    @Test("深浅两套取值齐全，SwiftUI 颜色随界面风格解析成各自那套；除白字外深浅确实不同")
    func bothThemesResolve() {
        for token in ColorToken.allCases {
            if token != .agentInk {
                #expect(token.themed.light != token.themed.dark, "\(token) 的深浅取值相同")
            }
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

/// `surface2` → `surface-2`，`primaryInk` → `primary-ink`，`agent16` → `agent-16`：稿子的变量名。
func designName(_ token: ColorToken) -> String {
    var name = ""
    var previous: Character?
    for character in String(describing: token) {
        if character.isUppercase || (character.isNumber && previous?.isNumber == false) { name.append("-") }
        name.append(Character(character.lowercased()))
        previous = character
    }
    return name
}

/// "#RRGGBB" 或 "#RRGGBBAA"。
func rgb(_ hex: String) -> RGB {
    let digits = hex.dropFirst()
    let value = UInt32(digits, radix: 16)!
    return digits.count == 8 ? RGB(rgba: value) : RGB(value)
}
