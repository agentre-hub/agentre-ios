import AgentreDesign
import Testing
import UIKit

struct IconTests {
    /// agentre-mobile.pen 里用到的全部 lucide 图标（pencil 遍历 type == "icon"，2026-09-29 读取），
    /// 去掉只画在示意状态栏里的 signal / wifi / battery-full——那是系统画的。
    static let design: Set<String> = [
        "arrow-down", "arrow-up", "brain", "check", "chevron-down", "chevron-left", "chevron-right", "chevron-up",
        "chevrons-up", "cpu", "ellipsis", "external-link", "file-pen", "file-search", "file-text", "folder",
        "folder-tree", "gauge", "github", "globe", "info", "languages", "list-filter", "list-plus", "log-out",
        "message-circle", "message-circle-question-mark", "monitor", "plug-zap", "plus", "search", "server",
        "shield-alert", "shield-check", "smartphone", "sparkles", "square", "square-pen", "sun-moon", "terminal",
        "trash-2", "user",
    ]

    @Test("图标枚举恰是稿子用到的 lucide 图标，原始值就是 lucide 名")
    func iconsAreTheDesignIcons() {
        #expect(Set(AgentreIcon.allCases.map(\.rawValue)) == Self.design)
    }

    @Test("每个图标都随包、24pt 见方、按模板着色，且真的画出了线条", arguments: AgentreIcon.allCases)
    func iconResolves(icon: AgentreIcon) throws {
        let image = try #require(UIImage(icon), "\(icon.rawValue) 不在资源包里")
        #expect(image.size == CGSize(width: 24, height: 24))
        #expect(image.renderingMode == .alwaysTemplate)
        #expect(inkedPixels(image) > 0, "\(icon.rawValue) 画出来是空的")
    }
}

/// 以黑色模板画到 24×24 的 RGBA8 位图上，数不透明的像素。
func inkedPixels(_ image: UIImage) -> Int {
    let side = 24
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        UIGraphicsPushContext(context)
        image.withTintColor(.black).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        UIGraphicsPopContext()
    }
    return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
}
