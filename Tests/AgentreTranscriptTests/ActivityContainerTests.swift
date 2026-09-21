import AgentreDesign
import AgentreDomain
@testable import AgentreUI
import SwiftUI
import Testing
import UIKit

/// 活动块不套容器：组头与步骤行都没有底色、边框或圆角。
///
/// 判据落在渲染出来的像素上：把展开的活动块托管进窗口、按两套主题各画一遍，逐个取每个可点行的
/// 命中区。行里只有文字与图标时，与列表底色不同的像素稀疏、且它们外接框的四条边也稀疏；
/// 一块底色把外接框整个填满，一圈描边把外接框的四条边描满——两者都判为容器。
@MainActor
@Suite("活动块不套容器")
struct ActivityContainerTests {
    let decoder = FakeDecoder()

    @Test("组头与每一行步骤都没有与列表底色不同的底色或边框（浅色、深色）", arguments: [Theme.light, Theme.dark])
    func noContainer(theme: Theme) async throws {
        let frames = [
            stored(decoder, 1, .userMessage("看一下")),
            stored(decoder, 2, .toolCall(readUse("r1"))), stored(decoder, 3, .toolResult(result("r1", "a\nb"))),
            stored(decoder, 4, .toolCall(use("c1", input: ["command": "pnpm test"]))), stored(decoder, 5, .toolResult(result("c1", #"{"exitCode":1,"output":"boom"}"#))),
            stored(decoder, 6, .toolCall(readUse("r2", path: "/repo/go.mod"))), stored(decoder, 7, .toolResult(result("r2", "module x"))),
            stored(decoder, 8, .turnDone(TurnDone(durationMs: 6600))),
        ]
        let model = TranscriptModel(conversation: SavedConversation(key: conversationKey, lifecycleState: "idle"), store: FakeStore(frames), relay: FakeRelay(), decoder: decoder)
        await model.load()
        guard case .activityHeader(let header)? = model.rows.first(where: { if case .activityHeader = $0.content { true } else { false } })?.content else {
            Issue.record("没有活动块组头"); return
        }
        model.toggle(header.blockKey, current: header.expanded)

        let collector = HitTargetCollector()
        let controller = UIHostingController(rootView: TranscriptView(model: model, agentName: "Claude Code").environment(\.hitTargetCollector, collector))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = theme == .dark ? .dark : .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<10 {
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }

        // 组头 + 3 行步骤。
        let targets = collector.frames.values.sorted { $0.minY < $1.minY }
        #expect(targets.count == 4, "\(targets)")

        let image = try #require(Snapshot(window))
        // 列表底色：取内容下方的空白处，并核对它就是这套主题的 bg token。
        let background = image.pixel(x: 195, y: 820)
        let token = ColorToken.bg.rgb(in: theme)
        #expect(background.distance(to: Pixel(r: token.red, g: token.green, b: token.blue)) <= 3, "底色 \(background) 不是 bg token \(token)")

        for frame in targets {
            let ink = image.ink(in: frame.insetBy(dx: 1, dy: 1), against: background)
            // 行里的文字确实画出来了：否则下面两条会空转。
            #expect(ink.coverage > 0.005, "\(frame) 里什么都没画出来")
            #expect(ink.coverage < 0.3, "\(frame) 里与底色不同的像素占 \(ink.coverage)：像一块底色")
            #expect(ink.edgeCoverage < 0.6, "\(frame) 的非底色外接框四边被描到 \(ink.edgeCoverage)：像一圈边框或一块底色")
        }
    }
}

fileprivate struct Pixel: CustomStringConvertible {
    var r: UInt8, g: UInt8, b: UInt8

    func distance(to other: Pixel) -> Int {
        max(abs(Int(r) - Int(other.r)), abs(Int(g) - Int(other.g)), abs(Int(b) - Int(other.b)))
    }

    var description: String { "rgb(\(r),\(g),\(b))" }
}

/// 以 1 点 = 1 像素、sRGB 画下整个窗口。
fileprivate struct Snapshot {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    @MainActor
    init?(_ window: UIWindow) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        // 测试进程里的窗口不上屏，drawHierarchy 只得到一片黑；直接渲染图层树。
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    func pixel(x: Int, y: Int) -> Pixel {
        let index = (y * width + x) * 4
        return Pixel(r: bytes[index], g: bytes[index + 1], b: bytes[index + 2])
    }

    /// 区域里与底色不同的像素：占区域的比例，以及它们外接框四条边上被占的比例（取最大的一条）。
    func ink(in rect: CGRect, against background: Pixel) -> (coverage: Double, edgeCoverage: Double) {
        let x0 = max(0, Int(rect.minX.rounded(.up))), x1 = min(width - 1, Int(rect.maxX.rounded(.down)))
        let y0 = max(0, Int(rect.minY.rounded(.up))), y1 = min(height - 1, Int(rect.maxY.rounded(.down)))
        guard x0 < x1, y0 < y1 else { return (0, 0) }
        func isInk(_ x: Int, _ y: Int) -> Bool { pixel(x: x, y: y).distance(to: background) > 2 }
        var count = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in y0...y1 {
            for x in x0...x1 where isInk(x, y) {
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let coverage = Double(count) / Double((x1 - x0 + 1) * (y1 - y0 + 1))
        guard count > 0, maxX > minX, maxY > minY else { return (coverage, 0) }
        func rowCoverage(_ y: Int) -> Double { Double((minX...maxX).count { isInk($0, y) }) / Double(maxX - minX + 1) }
        func columnCoverage(_ x: Int) -> Double { Double((minY...maxY).count { isInk(x, $0) }) / Double(maxY - minY + 1) }
        return (coverage, max(rowCoverage(minY), rowCoverage(maxY), columnCoverage(minX), columnCoverage(maxX)))
    }
}
