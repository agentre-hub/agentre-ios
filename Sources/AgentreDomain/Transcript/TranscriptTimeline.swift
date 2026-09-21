import Foundation

/// 合流：本地库、向机器补拉的历史与实时帧按 seq 合成一条。
///
/// - 带号帧按 seq 排序，同号只留先到的那份（机器是权威，同号即同一帧）；
/// - 不带号的实时帧（轮次边界）排在它到达时已知的最大帧号之后；
/// - 预览帧是过场：挂在末尾，下一条更新的持久帧一到就被取代（向前补的更早帧不算）。
public struct TranscriptTimeline: Sendable {
    private var numbered: [Int64: TranscriptEvent] = [:]
    private var sortedSeqs: [Int64] = []
    private var unnumbered: [(after: Int64, order: Int, event: TranscriptEvent)] = []
    private var previews: [TranscriptEvent] = []
    private var nextOrder = 0

    public init() {}

    /// 放进一帧；这一帧改变了转录时为 true（重复帧号为 false）。
    @discardableResult
    public mutating func insert(seq: Int64?, event: TranscriptEvent, preview: Bool = false) -> Bool {
        if preview {
            previews.append(event)
            return true
        }
        if let seq {
            guard numbered[seq] == nil else { return false }
            // 只有比已知最新更新的帧才取代预览尾巴；向前补进来的更早帧与还在流的回复无关。
            let supersedes = seq > (latestSeq ?? 0)
            numbered[seq] = event
            let index = sortedSeqs.partitioningIndex { $0 >= seq }
            sortedSeqs.insert(seq, at: index)
            if supersedes { previews.removeAll() }
        } else {
            unnumbered.append((latestSeq ?? 0, nextOrder, event))
            nextOrder += 1
            previews.removeAll()
        }
        return true
    }

    public var oldestSeq: Int64? { sortedSeqs.first }
    public var latestSeq: Int64? { sortedSeqs.last }
    /// 带号帧的条数。
    public var count: Int { sortedSeqs.count }

    public var entries: [TimelineEntry] {
        var result: [TimelineEntry] = []
        result.reserveCapacity(sortedSeqs.count + unnumbered.count + previews.count)
        let loose = unnumbered.sorted { ($0.after, $0.order) < ($1.after, $1.order) }
        var next = 0
        for seq in sortedSeqs {
            while next < loose.count, loose[next].after < seq {
                result.append(TimelineEntry(anchor: "u\(loose[next].after).\(loose[next].order)", event: loose[next].event))
                next += 1
            }
            result.append(TimelineEntry(anchor: "s\(seq)", event: numbered[seq]!))
        }
        for item in loose[next...] {
            result.append(TimelineEntry(anchor: "u\(item.after).\(item.order)", event: item.event))
        }
        for (index, event) in previews.enumerated() {
            result.append(TimelineEntry(anchor: "p\(index)", event: event, preview: true))
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
