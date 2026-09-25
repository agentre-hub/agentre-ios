import AgentreDomain

/// 列表里的一格。
///
/// 一段正文在屏上是一整块文字，每来一片增量就要把整块重新排版一遍：上万字的回复一片要排好几百毫秒，
/// 转录便越流越落后于机器。所以极长的正文按空行切成几格，一片增量只重排最末那一格。
struct TranscriptCell: Identifiable, Equatable {
    enum Content: Equatable {
        case row(TranscriptRow)
        /// 正文切出来的一段，以及它所在的那一行。
        case text(TextSegment, row: String)
    }

    let id: String
    let content: Content

    var segment: TextSegment? {
        if case .text(let segment, _) = content { segment } else { nil }
    }
}

/// 正文切出来的一段。格子之间就是原文里的一个换行：切口落在空行的第一个换行上，后一段以余下的换行开头。
struct TextSegment: Equatable {
    var text: String
    /// 这一段是正文的开头 / 结尾：正文上下的留白只加在两端。
    var first: Bool
    var last: Bool
}

enum TranscriptCells {
    /// 一格至少这么多字节（UTF-8，约一千个汉字）才在下一个空行处切开。
    static let segmentBytes = 3_000

    static func build(_ rows: [TranscriptRow]) -> [TranscriptCell] {
        var cells: [TranscriptCell] = []
        cells.reserveCapacity(rows.count)
        for row in rows {
            guard case .text(let text, _) = row.content else {
                cells.append(TranscriptCell(id: row.id, content: .row(row)))
                continue
            }
            let pieces = split(text)
            for (index, piece) in pieces.enumerated() {
                cells.append(TranscriptCell(
                    id: index == 0 ? row.id : "\(row.id)#\(index)",
                    content: .text(TextSegment(text: piece, first: index == 0, last: index == pieces.count - 1), row: row.id)
                ))
            }
        }
        return cells
    }

    /// `row` 那一行的整段正文。
    static func reply(_ row: String, in rows: [TranscriptRow]) -> String? {
        guard case .text(let text, _) = rows.first(where: { $0.id == row })?.content else { return nil }
        return text
    }

    /// 从头往后切：切口只取决于它之前的文字，所以正文往后长时，除最末一段外各段原样不动。
    ///
    /// 行内 Markdown 的代码可以跨空行（围栏代码块也按它解析成一段代码），切在里面会把两半都排坏；
    /// 所以代码没闭合时的空行不算切口。代码按反引号串配对：开头的串要等到一样长的串才闭合，代码外的反斜杠转义下一个字符。
    static func split(_ text: String) -> [String] {
        let bytes = text.utf8
        guard bytes.count > segmentBytes else { return [text] }
        var pieces: [String] = []
        var start = bytes.startIndex
        var index = bytes.startIndex
        /// 未闭合的代码开头那串反引号的长度；0 表示不在代码里。
        var openTicks = 0
        while index < bytes.endIndex {
            let byte = bytes[index]
            var next = bytes.index(after: index)
            if byte == UInt8(ascii: "`") {
                var run = 1
                while next < bytes.endIndex, bytes[next] == UInt8(ascii: "`") {
                    run += 1
                    next = bytes.index(after: next)
                }
                if openTicks == 0 { openTicks = run } else if openTicks == run { openTicks = 0 }
            } else if byte == UInt8(ascii: "\\"), openTicks == 0, next < bytes.endIndex {
                next = bytes.index(after: next)
            } else if byte == 0x0A, openTicks == 0, next < bytes.endIndex, bytes[next] == 0x0A,
                      bytes.distance(from: start, to: index) >= segmentBytes {
                pieces.append(String(text[start..<index]))
                start = next
            }
            index = next
        }
        pieces.append(String(text[start...]))
        return pieces
    }
}
