import AgentreDomain

/// 列表里的一格。
///
/// 一段正文在屏上是一整块文字，每来一片增量就要把整块重新排版一遍：上万字的回复一片要排好几百毫秒，
/// 转录便越流越落后于机器。所以极长的正文按空行切成几格，一片增量只重排最末那一格。
struct TranscriptCell: Identifiable, Equatable {
    enum Content: Equatable {
        case row(TranscriptRow)
        case text(TextSegment)
    }

    let id: String
    let content: Content

    var segment: TextSegment? {
        if case .text(let segment) = content { segment } else { nil }
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
                    content: .text(TextSegment(text: piece, first: index == 0, last: index == pieces.count - 1))
                ))
            }
        }
        return cells
    }

    /// 从头往后切：切口只取决于它之前的文字，所以正文往后长时，除最末一段外各段原样不动。
    static func split(_ text: String) -> [String] {
        let bytes = text.utf8
        guard bytes.count > segmentBytes else { return [text] }
        var pieces: [String] = []
        var start = bytes.startIndex
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let next = bytes.index(after: index)
            if bytes[index] == 0x0A, next < bytes.endIndex, bytes[next] == 0x0A,
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
