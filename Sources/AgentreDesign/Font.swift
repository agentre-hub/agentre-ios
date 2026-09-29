import CoreText
import SwiftUI
import UIKit

/// 随包字重。JetBrains Mono 只随包 400 / 600：medium 取 400，bold 取 600。
public enum FontWeight: Sendable, CaseIterable {
    case regular
    case medium
    case semibold
    case bold
}

/// 一档字：稿子里的字号（pt）、默认字重，以及随系统字号缩放时跟随的文本样式。
public struct FontRole: Sendable, Equatable {
    public let size: CGFloat
    public let weight: FontWeight
    public let textStyle: Font.TextStyle

    public init(size: CGFloat, weight: FontWeight = .regular, relativeTo textStyle: Font.TextStyle) {
        self.size = size
        self.weight = weight
        self.textStyle = textStyle
    }

    /// 顶层页大标题。
    public static let display = FontRole(size: 30, weight: .bold, relativeTo: .largeTitle)
    public static let title = FontRole(size: 21, weight: .semibold, relativeTo: .title2)
    public static let headline = FontRole(size: 17, weight: .semibold, relativeTo: .headline)
    public static let body = FontRole(size: 15, relativeTo: .body)
    public static let callout = FontRole(size: 14, relativeTo: .callout)
    public static let subheadline = FontRole(size: 13, relativeTo: .subheadline)
    public static let footnote = FontRole(size: 12, relativeTo: .footnote)
    public static let caption = FontRole(size: 11.5, relativeTo: .caption)
    public static let caption2 = FontRole(size: 10.5, relativeTo: .caption2)
}

/// 随包的六个字面，资源名就是 PostScript 名。
enum FontFace: String, CaseIterable {
    case interRegular = "Inter-Regular"
    case interMedium = "Inter-Medium"
    case interSemiBold = "Inter-SemiBold"
    case interBold = "Inter-Bold"
    case monoRegular = "JetBrainsMono-Regular"
    case monoSemiBold = "JetBrainsMono-SemiBold"

    /// 人类可读文本用 Inter，机器产出的内容用 JetBrains Mono。
    init(mono: Bool, weight: FontWeight) {
        switch (mono, weight) {
        case (false, .regular): self = .interRegular
        case (false, .medium): self = .interMedium
        case (false, .semibold): self = .interSemiBold
        case (false, .bold): self = .interBold
        case (true, .regular), (true, .medium): self = .monoRegular
        case (true, .semibold), (true, .bold): self = .monoSemiBold
        }
    }

    /// 首次取字时把六个字面注册进本进程；之后按 PostScript 名即可解析。
    ///
    /// 字体以 .xcassets 数据集随包（资源清单冻结，SwiftPM 只自动处理资源目录）。CoreText 只肯按文件注册：
    /// 从内存数据建的描述符注册会被拒（信息不足），按图形字体注册已弃用。所以先落到临时目录再按 URL 注册。
    static let registered: Void = {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AgentreFonts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for face in allCases {
            guard let data = NSDataAsset(name: face.rawValue, bundle: .module)?.data else {
                assertionFailure("随包字体 \(face.rawValue) 不在资源包里")
                continue
            }
            let url = directory.appending(path: "\(face.rawValue).ttf")
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                assertionFailure("随包字体 \(face.rawValue) 落盘失败：\(error)")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                assertionFailure("随包字体 \(face.rawValue) 注册失败：\(String(describing: error?.takeRetainedValue()))")
            }
        }
    }()
}

extension UIFont {
    /// 界面取字的 UIKit 入口：随包字体，按角色的文本样式随系统字号缩放。
    public static func agentre(
        _ role: FontRole, mono: Bool = false, weight: FontWeight? = nil, compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        FontFace.registered
        let face = FontFace(mono: mono, weight: weight ?? role.weight)
        guard let base = UIFont(name: face.rawValue, size: role.size) else {
            assertionFailure("随包字体 \(face.rawValue) 解析不到")
            return .preferredFont(forTextStyle: role.textStyle.uiTextStyle, compatibleWith: traits)
        }
        return UIFontMetrics(forTextStyle: role.textStyle.uiTextStyle).scaledFont(for: base, compatibleWith: traits)
    }
}

extension Font {
    /// 界面取字的唯一入口：随包字体，按角色的文本样式随系统字号缩放。
    public static func agentre(_ role: FontRole, mono: Bool = false, weight: FontWeight? = nil) -> Font {
        FontFace.registered
        return .custom(FontFace(mono: mono, weight: weight ?? role.weight).rawValue, size: role.size, relativeTo: role.textStyle)
    }
}

extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}
