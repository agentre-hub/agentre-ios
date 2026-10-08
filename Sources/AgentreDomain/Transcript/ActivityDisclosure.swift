import Foundation

/// 活动块的运行态规则，移植自宿主 agentre-ui 的 activity-block/block.tsx。
public enum ActivityDisclosure {
    /// 运行中超过这么多步就省略。8 行约等于「还能一眼扫完」的上限。
    public static let runningElideOver = 8
    /// 省略时保留末尾这么多行，足以看出 agent 此刻在什么节奏上。
    public static let runningTail = 6

    /// - Parameters:
    ///   - running: 这一块此刻在跑：自动展开；落定后回到默认（自动收起）。
    ///   - defaultExpanded: 用户没碰过时的默认展开态。
    ///   - userExpanded: 用户点过组头后的选择；此后以它为准，不被自动收起覆盖。
    ///   - userShowAll: 用户点过省略行。
    ///   - durationMs: 调用方给的整轮耗时。没有块级来源，所以运行中留空。
    public static func layout(
        stepCount: Int,
        running: Bool,
        defaultExpanded: Bool = false,
        userExpanded: Bool? = nil,
        userShowAll: Bool = false,
        durationMs: Int? = nil
    ) -> ActivityBlockLayout {
        let elided = running && !userShowAll && stepCount > runningElideOver ? stepCount - runningTail : 0
        let duration = !running && (durationMs ?? 0) > 0 ? durationMs : nil
        return ActivityBlockLayout(
            showsHeader: stepCount > 1,
            expanded: userExpanded ?? (running || defaultExpanded),
            elidedCount: elided,
            durationMs: duration
        )
    }
}

extension TranscriptFollow {
    /// 用户向上滚离了底部：停止自动跟随。
    public mutating func userScrolledAway() {
        isFollowing = false
    }

    /// 用户自己滚回了底部：恢复跟随，新增计数清零。
    public mutating func reachedBottom() {
        isFollowing = true
        unseen = 0
    }

    /// 末尾新增了几行；不在跟随时计入「其间新增」。
    public mutating func appended(_ count: Int) {
        guard !isFollowing, count > 0 else { return }
        unseen += count
    }

    /// 点了回到最新。
    public mutating func jumpToLatest() {
        reachedBottom()
    }
}
