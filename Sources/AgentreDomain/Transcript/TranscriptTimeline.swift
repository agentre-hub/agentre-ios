import Foundation

/// 合流：本地库、向机器补拉的历史与实时帧按 seq 合成一条。
///
/// - 带号帧按 seq 排序，同号只留先到的那份（机器是权威，同号即同一帧）；
/// - 不带号的实时帧（轮次边界）排在它到达时已知的最大帧号之后；
/// - 预览帧是过场：只取正文与思考两种增量，接成挂在末尾的尾巴，下一条更新的持久帧一到就被取代
///   （向前补的更早帧不算）。尾巴不进 `entries`：一篇长回复有上万片预览，每次都从头归约一遍，
///   一片的代价便随回复变长。
public struct TranscriptTimeline: Sendable {
    private var numbered: [Int64: (event: TranscriptEvent, time: Int64)] = [:]
    private var sortedSeqs: [Int64] = []
    private var unnumbered: [(after: Int64, order: Int, event: TranscriptEvent, time: Int64)] = []
    private var nextOrder = 0
    /// 预览尾巴：还在流的正文与思考。
    public private(set) var liveText = ""
    public private(set) var liveThinking = ""

    public init() {}

    /// 放进一帧；这一帧改变了转录时为 true（重复帧号为 false）。
    /// - Parameter time: 这一帧的时刻（Unix 毫秒）；0 = 不知道。
    @discardableResult
    public mutating func insert(seq: Int64?, event: TranscriptEvent, preview: Bool = false, time: Int64 = 0) -> Bool {
        if preview {
            switch event {
            case .textDelta(let text): liveText += text
            case .thinkingDelta(let text): liveThinking += text
            default: return false
            }
            return true
        }
        if let seq {
            guard numbered[seq] == nil else { return false }
            // 只有比已知最新更新的帧才取代预览尾巴；向前补进来的更早帧与还在流的回复无关。
            let supersedes = seq > (latestSeq ?? 0)
            numbered[seq] = (event, time)
            let index = sortedSeqs.partitioningIndex { $0 >= seq }
            sortedSeqs.insert(seq, at: index)
            if supersedes { clearPreview() }
        } else {
            unnumbered.append((latestSeq ?? 0, nextOrder, event, time))
            nextOrder += 1
            clearPreview()
        }
        return true
    }

    private mutating func clearPreview() {
        liveText = ""
        liveThinking = ""
    }

    public var oldestSeq: Int64? { sortedSeqs.first }
    public var latestSeq: Int64? { sortedSeqs.last }
    /// 带号帧的条数。
    public var count: Int { sortedSeqs.count }

    public var entries: [TimelineEntry] {
        var result: [TimelineEntry] = []
        result.reserveCapacity(sortedSeqs.count + unnumbered.count)
        let loose = unnumbered.sorted { ($0.after, $0.order) < ($1.after, $1.order) }
        var next = 0
        for seq in sortedSeqs {
            while next < loose.count, loose[next].after < seq {
                result.append(TimelineEntry(anchor: "u\(loose[next].after).\(loose[next].order)", event: loose[next].event, time: loose[next].time))
                next += 1
            }
            let frame = numbered[seq]!
            result.append(TimelineEntry(anchor: "s\(seq)", event: frame.event, time: frame.time))
        }
        for item in loose[next...] {
            result.append(TimelineEntry(anchor: "u\(item.after).\(item.order)", event: item.event, time: item.time))
        }
        return result
    }
}

extension Array {
    /// 第一个满足谓词的下标（数组须已按谓词分区）。
    func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if belongsInSecondPartition(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
