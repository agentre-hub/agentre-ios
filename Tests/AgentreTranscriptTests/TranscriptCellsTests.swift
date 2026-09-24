import AgentreDomain
@testable import AgentreUI
import SwiftUI
import Testing
import UIKit

/// 转录行 → 列表格子：极长的正文按空行切成几格。
@Suite("转录格子")
struct TranscriptCellsTests {
    @Test("短正文与其它行各占一格，格子的 id 就是行的 id")
    func shortRowsAreOneCellEach() {
        let rows = [
            TranscriptRow(id: "u", content: .user("写一篇长文")),
            TranscriptRow(id: "t", content: .text("第一段\n\n第二段", streaming: false)),
        ]
        let cells = TranscriptCells.build(rows)
        #expect(cells.map(\.id) == ["u", "t"])
        #expect(cells[1].segment == TextSegment(text: "第一段\n\n第二段", first: true, last: true))
        #expect(cells[0].segment == nil)
    }

    @Test("长正文在空行处切开：依次拼回（格子之间就是那一个换行）与原文逐字相同，每格不短于下限，首格沿用行的 id")
    func longTextSplitsAtBlankLines() {
        let text = operatingSystemsEssay
        let cells = TranscriptCells.build([TranscriptRow(id: "t", content: .text(text, streaming: false))])
        #expect(cells.count > 5)
        #expect(cells.first?.id == "t")
        #expect(Set(cells.map(\.id)).count == cells.count)
        let segments = cells.compactMap(\.segment)
        #expect(segments.map(\.text).joined(separator: "\n") == text)
        #expect(segments.first?.first == true && segments.dropFirst().allSatisfy { !$0.first })
        #expect(segments.last?.last == true && segments.dropLast().allSatisfy { !$0.last })
        for segment in segments.dropLast() {
            #expect(segment.text.utf8.count >= TranscriptCells.segmentBytes)
            #expect(!segment.text.hasSuffix("\n"), "切口不在空行的第一个换行上：\(segment.text.suffix(20))")
        }
        for segment in segments.dropFirst() {
            #expect(segment.text.hasPrefix("\n"))
        }
    }

    @Test("回复往后长时，除最末一格外的格子原样不动（一片增量只重排最末那一格）")
    func growingTextKeepsEarlierCells() {
        let text = Array(operatingSystemsEssay)
        var previous: [TranscriptCell] = []
        for length in stride(from: 500, through: text.count, by: 377) {
            let cells = TranscriptCells.build([TranscriptRow(id: "t", content: .text(String(text[0..<length]), streaming: true))])
            let settled = previous.dropLast()
            #expect(Array(cells.prefix(settled.count)) == Array(settled), "写到 \(length) 字时前面的格子变了")
            previous = cells
        }
    }

    @Test("没有空行的一整段不切（行内 Markdown 可以跨单个换行）")
    func noBlankLineNoSplit() {
        let text = String(repeating: "一句没有空行的长文，**加粗\n跨行**也照样成立。", count: 400)
        let cells = TranscriptCells.build([TranscriptRow(id: "t", content: .text(text, streaming: false))])
        #expect(cells.count == 1)
    }

    @Test("切开后逐格叠起来与整段一样高：读者看到的排版不变")
    @MainActor
    func segmentsStackToTheSameHeight() {
        let text = operatingSystemsEssay
        let segments = TranscriptCells.build([TranscriptRow(id: "t", content: .text(text, streaming: false))]).compactMap(\.segment)
        /// 放进窗口里量（屏幕的像素密度参与取整），宽度与 iPhone 17 上的正文一样。
        func height(_ view: some View) -> CGFloat {
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 370, height: 874))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            return controller.sizeThatFits(in: CGSize(width: 370, height: CGFloat.infinity)).height
        }
        let whole = height(AgentText(segment: TextSegment(text: text, first: true, last: true)))
        let stacked = height(VStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { AgentText(segment: $0.element) }
        })
        #expect(segments.count > 5)
        // 每个切口至多差出一个像素的取整（屏幕 3 倍像素：1/3pt）。
        #expect(abs(stacked - whole) <= CGFloat(segments.count - 1) / 3, "整段 \(whole)pt，逐格叠起来 \(stacked)pt（\(segments.count) 格）")
    }
}
