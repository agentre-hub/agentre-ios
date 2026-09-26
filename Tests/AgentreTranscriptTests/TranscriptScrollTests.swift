import AgentreDomain
@testable import AgentreUI
import Darwin
import SwiftUI
import Testing
import UIKit

/// 自动跟随的真实接线：把转录托管进窗口，直接拨动列表底下的 UIScrollView，
/// 再看视图模型与屏上的「回到最新」。
@MainActor
@Suite("转录滚动接线")
struct TranscriptScrollTests {
    let decoder = FakeDecoder()

    @Test("上滚即停自动跟随；其间来的新行记数并出现在「回到最新」上；点它回到底部并清零")
    func scrollingUpStopsFollowing() async throws {
        let frames = (1...40).map { stored(decoder, Int64($0), .userMessage("第 \($0) 句")) }
        let model = TranscriptModel(
            conversation: SavedConversation(key: conversationKey, lifecycleState: "idle"),
            store: FakeStore(frames), relay: FakeRelay(), decoder: decoder
        )
        let host = ScrollHost(TranscriptView(model: model, agentName: "Claude Code"))
        try await host.settle { model.rows.count == 40 }
        try await host.settle { host.scrollView() != nil }
        let scrollView = try #require(host.scrollView(), "转录底下没有 UIScrollView：\(host.describeScrollViews())")

        // 打开即在底部、在跟随。
        try await host.settle { host.isAtBottom(scrollView) }
        #expect(model.follow.isFollowing)

        // 新内容到达时跟随：仍停在底部，不计数。
        model.merge(live: [liveFrame(decoder, 41, .userMessage("第 41 句"))])
        try await host.settle { host.isAtBottom(scrollView) && model.rows.count == 41 }
        #expect(model.follow.isFollowing)
        #expect(model.follow.unseen == 0)

        // 用户上滚。
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
        try await host.settle("上滚后仍在跟随：\(host.describe(scrollView))") { !model.follow.isFollowing }

        model.merge(live: [liveFrame(decoder, 42, .userMessage("第 42 句")), liveFrame(decoder, 43, .userMessage("第 43 句"))])
        try await host.settle { model.follow.unseen == 2 }
        // 不跟随：新行没有把视口拖回底部。
        #expect(!host.isAtBottom(scrollView))
        let jumpLabel = String(format: text("transcript.jumpToLatest %lld"), locale: Locale.current, 2)
        let found = await host.element(labelled: jumpLabel)
        let onScreen = await host.labels()
        let jump = try #require(found, "屏上没有「\(jumpLabel)」：\(onScreen)")

        #expect(jump.accessibilityActivate())
        try await host.settle("跳回底部：following=\(model.follow.isFollowing) \(host.describeScrollViews()) offset=\(scrollView.contentOffset) insets=\(scrollView.adjustedContentInset)") { host.isAtBottom(scrollView) }
        #expect(model.follow.isFollowing)
        #expect(model.follow.unseen == 0)
        try await host.settle { await host.element(labelled: jumpLabel) == nil }
    }

    @Test("跟随中可见高度缩小（键盘弹回、回前台）后仍贴在最新一行")
    func followingSurvivesShrinkingViewport() async throws {
        let (model, host, scrollView) = try await openAtBottom(rows: 40)

        host.shrinkViewport(by: 336)
        try await host.settle("缩小后没有贴底：\(host.describe(scrollView))") { host.isAtBottom(scrollView) }
        #expect(model.follow.isFollowing)
        #expect(host.isShowingLastRow(scrollView, model: model))
    }

    @Test("跟随中列表下面的输入区被键盘顶起（列表本身变矮，内容与偏移都不变）：仍贴在最新一行")
    func followingSurvivesComposerPushedUp() async throws {
        let (model, host, scrollView) = try await openAtBottom(rows: 40, composer: true)

        // 回前台：后台期间行已到齐、贴好了底；键盘这时才弹回来，把输入区顶上去，列表从底边矮下去一截。
        host.shrinkViewport(by: 246)
        try await host.settle("列表变矮后没有贴底：\(host.describe(scrollView))") { host.isShowingLastRow(scrollView, model: model) }
        #expect(model.follow.isFollowing)

        // 键盘收起再弹出：仍贴着底。
        host.shrinkViewport(by: 0)
        try await host.settle { host.isAtBottom(scrollView) }
        host.shrinkViewport(by: 246)
        try await host.settle("再次变矮后没有贴底：\(host.describe(scrollView))") { host.isShowingLastRow(scrollView, model: model) }
        try await host.frames(5)
        #expect(model.follow.isFollowing)

        // 补贴底没有留下记号认领用户随后的上滚。
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y - 200), animated: false)
        try await host.settle("上滚后仍在跟随：\(host.describe(scrollView))") { !model.follow.isFollowing }
    }

    @Test("跟随中行变化与可见高度缩小同时到来，最新一行仍可见")
    func followingSurvivesRowsAndShrinkTogether() async throws {
        let (model, host, scrollView) = try await openAtBottom(rows: 40)

        // 回前台：补回的行、摘要刷新与弹回的键盘在同一轮里到来。
        model.merge(live: [liveFrame(decoder, 41, .userMessage("第 41 句")), liveFrame(decoder, 42, .textDelta("后台里跑完的回复"))])
        host.shrinkViewport(by: 336)
        try await host.settle("同时到来后没有贴底：\(host.describe(scrollView))") { host.isAtBottom(scrollView) && model.rows.count >= 42 }
        #expect(model.follow.isFollowing)
        #expect(model.follow.unseen == 0)
        #expect(host.isShowingLastRow(scrollView, model: model))

        // 键盘收起再弹出：仍在底部。
        host.shrinkViewport(by: 0)
        try await host.settle { host.isAtBottom(scrollView) }
        host.shrinkViewport(by: 336)
        try await host.settle("再次缩小后没有贴底：\(host.describe(scrollView))") { host.isAtBottom(scrollView) }
        #expect(model.follow.isFollowing)
    }

    @Test("已上滚时可见高度变化与新行都不把视口拉回；「回到最新」记数照旧")
    func scrolledAwayIsNotYankedBackByLayout() async throws {
        let (model, host, scrollView) = try await openAtBottom(rows: 40)

        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
        try await host.settle("上滚后仍在跟随：\(host.describe(scrollView))") { !model.follow.isFollowing }
        let away = scrollView.contentOffset.y

        model.merge(live: [liveFrame(decoder, 41, .userMessage("第 41 句")), liveFrame(decoder, 42, .userMessage("第 42 句"))])
        host.shrinkViewport(by: 336)
        try await host.settle { model.follow.unseen == 2 }
        try await host.frames(15)
        #expect(!model.follow.isFollowing)
        #expect(model.follow.unseen == 2)
        #expect(!host.isAtBottom(scrollView))
        #expect(abs(scrollView.contentOffset.y - away) < 2, "视口被挪动了：\(host.describe(scrollView))")

        host.shrinkViewport(by: 0)
        try await host.frames(15)
        #expect(!model.follow.isFollowing)
        #expect(!host.isAtBottom(scrollView))
    }

    @Test("键盘弹着时稍稍上滚也停止跟随，其后的新行不把视口拉回")
    func scrollingUpWithKeyboardStopsFollowing() async throws {
        let (model, host, scrollView) = try await openAtBottom(rows: 40)
        // 从一开始就让出底部（键盘弹着打开对话）：打开时贴底不依赖本任务的改动。
        host.shrinkViewport(by: 336)
        try await host.settle { scrollView.adjustedContentInset.bottom > 300 }
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom), animated: false)
        try await host.settle("没有贴底：\(host.describe(scrollView))") { host.isAtBottom(scrollView) }
        try await host.frames(5)
        #expect(model.follow.isFollowing)

        // 上滚 200pt：比键盘矮，但确实离开了最新一行。
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y - 200), animated: false)
        try await host.settle("上滚 200pt 仍在跟随：\(host.describe(scrollView))") { !model.follow.isFollowing }
        let away = scrollView.contentOffset.y

        model.merge(live: [liveFrame(decoder, 41, .userMessage("第 41 句"))])
        try await host.settle { model.follow.unseen == 1 }
        try await host.frames(15)
        #expect(!model.follow.isFollowing)
        #expect(abs(scrollView.contentOffset.y - away) < 2, "视口被拉回：\(host.describe(scrollView))")
    }

    @Test("跟随中一大段流式回复落定（整行换成入库的那一行）、下一轮接着涌入：仍在底部跟随，不出现「回到最新」")
    func followingSurvivesSettledStreamingReply() async throws {
        let (model, host, scrollView) = try await openAtBottom(rows: 40)
        var seq: Int64 = 40
        func next() -> Int64 { seq += 1; return seq }
        // 几屏高的回复：预览帧逐段长出来，每段之间布局一次（回前台后补齐与实时流都是这样到的）。
        let paragraphs = (1...60).map { "第 \($0) 段：所有权、借用与生命周期的长篇说明，写得够长，让这一行撑到好几屏高。\n\n" }
        var frames = [liveFrame(decoder, next(), .userMessage("讲讲 Rust 的所有权")), liveFrame(decoder, next(), .turnStarted)]
        frames += paragraphs.map { liveFrame(decoder, nil, .textDelta($0), preview: true) }
        // 这一轮落定：预览那一行被入库的同一段文字取代；紧接着排队的下一句开了新的一轮。
        frames += [
            liveFrame(decoder, next(), .textDelta(paragraphs.joined())),
            liveFrame(decoder, next(), .turnDone(TurnDone(durationMs: 35_000))),
            liveFrame(decoder, next(), .userMessage("再讲讲 Kotlin 协程")),
            liveFrame(decoder, next(), .turnStarted),
            liveFrame(decoder, next(), .thinkingDelta("想一想")),
            liveFrame(decoder, next(), .toolCall(use("k-1"))),
            liveFrame(decoder, next(), .toolResult(result("k-1"))),
        ]
        for (index, frame) in frames.enumerated() {
            model.merge(live: [frame])
            try await host.frames(1)
            guard model.follow.isFollowing else {
                Issue.record("第 \(index) 帧后停止了跟随，用户并没有滚动：\(host.describe(scrollView))")
                return
            }
        }
        try await host.settle("没有回到底部：\(host.describe(scrollView))") { host.isAtBottom(scrollView) && host.isShowingLastRow(scrollView, model: model) }
        try await host.frames(15)
        #expect(model.follow.isFollowing)
        #expect(model.follow.unseen == 0)
        #expect(host.isAtBottom(scrollView), "\(host.describe(scrollView))")
        let jumpLabel = text("transcript.jumpToLatest")
        #expect(await host.element(labelled: jumpLabel) == nil, "屏上出现了「\(jumpLabel)」")
    }

    @Test("跟随中手指往上拖、第一步恰好碰上流式回复又长了一截：跟随照停，拖动不被贴底一帧帧拽回")
    func draggingUpWhileStreamingStopsFollowing() async throws {
        let (model, host, scrollView) = try await openAtBottom(rows: 40)
        host.beginDragging(scrollView)
        // 手指刚动的那一帧回复长了一截：内容变了，这一步不算滚动。
        model.merge(live: [liveFrame(decoder, 41, .userMessage("第 41 句"))])
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y - 8), animated: false)
        try await host.frames(1)
        // 手指接着往上拖，每帧挪一截（拖动是在当前偏移上累加的）。
        for _ in 0..<20 {
            scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y - 20), animated: false)
            try await host.frames(1)
        }
        host.endDragging(scrollView)
        try await host.settle("拖动上滚后仍在跟随：\(host.describe(scrollView))") { !model.follow.isFollowing }
        #expect(!host.isAtBottom(scrollView), "\(host.describe(scrollView))")
    }

    @Test("打开一条最后几条回复极长（上万 pt 一行）的对话：落在真正的最新一行上，并如实在跟随")
    func openingOnHugeRepliesLandsOnLastRow() async throws {
        var seq: Int64 = 0
        func next() -> Int64 { seq += 1; return seq }
        var frames = (1...20).map { _ in stored(decoder, next(), .userMessage("第 \(seq) 句")) }
        for (ask, reply) in [("写一篇 Rust 长文", rustEssay), ("只回两个字：好的", "好的"), ("写一篇操作系统长文", operatingSystemsEssay), ("只回两个字：好的", "好的")] {
            frames += [
                stored(decoder, next(), .userMessage(ask)),
                stored(decoder, next(), .turnStarted),
                stored(decoder, next(), .textDelta(reply)),
                stored(decoder, next(), .turnDone(TurnDone(durationMs: 1_000))),
            ]
        }
        let model = TranscriptModel(
            conversation: SavedConversation(key: conversationKey, lifecycleState: "idle"),
            store: FakeStore(frames), relay: FakeRelay(), decoder: decoder
        )
        let host = ScrollHost(TranscriptView(model: model, agentName: "Claude Code"), size: iPhone17)
        try await host.settle { !model.rows.isEmpty }
        try await host.settle { host.scrollView() != nil }
        let scrollView = try #require(host.scrollView(), "转录底下没有 UIScrollView：\(host.describeScrollViews())")
        try await host.settle("打开后不在最新一行：following=\(model.follow.isFollowing) \(host.describe(scrollView)) \(host.describeCells(scrollView))") {
            host.isShowingLastRow(scrollView, model: model)
        }
        try await host.frames(15)
        #expect(host.isShowingLastRow(scrollView, model: model), "\(host.describe(scrollView)) \(host.describeCells(scrollView))")
        #expect(model.follow.isFollowing)
        #expect(model.follow.unseen == 0)
        #expect(await host.element(labelled: text("transcript.jumpToLatest")) == nil)
    }

    @Test("跟随中一篇上万字的回复逐片流完、落定，后面再来一问一答：一路跟随，最终停在真正的最新一行")
    func followingHugeStreamingReplyEndsOnLastRow() async throws {
        let (model, host, scrollView) = try await openAtBottom(rows: 40, size: iPhone17)
        var seq: Int64 = 40
        func next() -> Int64 { seq += 1; return seq }
        var frames = [liveFrame(decoder, next(), .userMessage("写一篇操作系统长文")), liveFrame(decoder, next(), .turnStarted)]
        frames += pieces(of: operatingSystemsEssay, size: 120).map { liveFrame(decoder, nil, .textDelta($0), preview: true) }
        frames += [
            liveFrame(decoder, next(), .textDelta(operatingSystemsEssay)),
            liveFrame(decoder, next(), .turnDone(TurnDone(durationMs: 180_000))),
            liveFrame(decoder, next(), .userMessage("只回两个字：好的")),
            liveFrame(decoder, next(), .turnStarted),
            liveFrame(decoder, next(), .textDelta("好的")),
            liveFrame(decoder, next(), .turnDone(TurnDone(durationMs: 1_000))),
        ]
        for (index, frame) in frames.enumerated() {
            model.merge(live: [frame])
            try await host.frames(1)
            guard model.follow.isFollowing else {
                Issue.record("第 \(index) 帧后停止了跟随，用户并没有滚动：\(host.describe(scrollView))")
                return
            }
        }
        try await host.settle("没有停在最新一行：\(host.describe(scrollView)) \(host.describeCells(scrollView))") { host.isShowingLastRow(scrollView, model: model) }
        try await host.frames(15)
        #expect(host.isShowingLastRow(scrollView, model: model), "\(host.describe(scrollView)) \(host.describeCells(scrollView))")
        #expect(model.follow.isFollowing)
        #expect(model.follow.unseen == 0)
        #expect(await host.element(labelled: text("transcript.jumpToLatest")) == nil)
    }

    @Test("流式回复越写越长，每一片增量落到屏上的代价不随之变大：上万字的回复不会让转录落后于机器")
    func streamingDeltaCostDoesNotGrowWithReply() async throws {
        let (model, host, _) = try await openAtBottom(rows: 40, size: iPhone17)
        model.merge(live: [liveFrame(decoder, 41, .userMessage("写一篇操作系统长文")), liveFrame(decoder, 42, .turnStarted)])
        let essay = Array(operatingSystemsEssay)
        var written = 0
        /// 回复写到 `length` 字后，再逐片追加 20 小片、每片都落到屏上，所花的时间。
        /// 连量三轮取最短的：机器被别的活占满时，某一轮被抢走的时间不算进代价。
        func costOfDeltas(after length: Int) async throws -> Duration {
            model.merge(live: [liveFrame(decoder, nil, .textDelta(String(essay[written..<length])), preview: true)])
            written = length
            var fastest = Duration.seconds(3_600)
            for _ in 0..<3 {
                try await host.frames(5)
                let clock = ContinuousClock()
                let started = clock.now
                for _ in 0..<20 {
                    model.merge(live: [liveFrame(decoder, nil, .textDelta(String(essay[written..<written + 6])), preview: true)])
                    written += 6
                    host.controller.view.layoutIfNeeded()
                }
                fastest = min(fastest, clock.now - started)
            }
            return fastest
        }
        let short = try await costOfDeltas(after: 1_000)
        let long = try await costOfDeltas(after: 15_000)
        // 修前实测：1000 字时 20 片约 0.55 秒，15000 字时约 8.5 秒（15 倍）。
        #expect(long < short * 3, "回复 1000 字时 20 片最快花 \(short)，15000 字时最快花 \(long)")
    }

    @Test("切成几格的长回复，在任一格上拷贝得到的都是整条回复，不是看不出边界的一截")
    func copyingASplitReplyCopiesTheWholeReply() async throws {
        let frames = [
            stored(decoder, 1, .userMessage("写一篇操作系统长文")),
            stored(decoder, 2, .turnStarted),
            stored(decoder, 3, .textDelta(operatingSystemsEssay)),
            stored(decoder, 4, .turnDone(TurnDone(durationMs: 1_000))),
        ]
        let model = TranscriptModel(
            conversation: SavedConversation(key: conversationKey, lifecycleState: "idle"),
            store: FakeStore(frames), relay: FakeRelay(), decoder: decoder
        )
        let host = ScrollHost(TranscriptView(model: model, agentName: "Claude Code"), size: iPhone17)
        try await host.settle { !model.rows.isEmpty }
        let segments = TranscriptCells.build(model.rows).compactMap(\.segment)
        #expect(segments.count > 1)
        let last = String(AgentText.rendered(try #require(segments.last).text).characters)
        try await host.settle { await host.element(labelled: last) != nil }
        let element = try #require(await host.element(labelled: last))
        let copy = (element.accessibilityCustomActions ?? []).filter { $0.name == text("transcript.copyReply") }
        #expect(copy.count == 1, "末格的动作：\((element.accessibilityCustomActions ?? []).map(\.name))")
        let action = try #require(copy.first)
        let pasteboard = try #require(UIPasteboard(name: UIPasteboard.Name("transcript-copy-test"), create: true))
        AgentText.pasteboard = pasteboard
        defer {
            AgentText.pasteboard = .general
            UIPasteboard.remove(withName: pasteboard.name)
        }
        if let handler = action.actionHandler {
            #expect(handler(action))
        } else {
            _ = (action.target as? NSObject)?.perform(action.selector, with: action)
        }
        #expect(pasteboard.string == operatingSystemsEssay)
    }

    /// 打开 `rows` 句的转录，等它在底部、在跟随。
    /// `composer`：列表下面垫一块输入区（对话屏的样子），键盘让出的底部由它让，列表本身变矮。
    private func openAtBottom(rows count: Int, size: CGSize = CGSize(width: 390, height: 844), composer: Bool = false) async throws -> (TranscriptModel, ScrollHost, UIScrollView) {
        let frames = (1...count).map { stored(decoder, Int64($0), .userMessage("第 \($0) 句")) }
        let model = TranscriptModel(
            conversation: SavedConversation(key: conversationKey, lifecycleState: "idle"),
            store: FakeStore(frames), relay: FakeRelay(), decoder: decoder
        )
        let transcript = TranscriptView(model: model, agentName: "Claude Code")
        let host = composer
            ? ScrollHost(VStack(spacing: 0) { transcript; Color.gray.frame(height: 96) }, size: size)
            : ScrollHost(transcript, size: size)
        try await host.settle { model.rows.count == count }
        try await host.settle { host.scrollView() != nil }
        let scrollView = try #require(host.scrollView(), "转录底下没有 UIScrollView：\(host.describeScrollViews())")
        try await host.settle { host.isAtBottom(scrollView) }
        #expect(model.follow.isFollowing)
        return (model, host, scrollView)
    }

    /// iPhone 17 的逻辑尺寸。
    let iPhone17 = CGSize(width: 402, height: 874)

    /// 把一段文字切成一片片流式增量。
    func pieces(of text: String, size: Int) -> [String] {
        let characters = Array(text)
        return stride(from: 0, to: characters.count, by: size).map { String(characters[$0..<min($0 + size, characters.count)]) }
    }

    func text(_ key: String) -> String {
        AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Conversation")
    }
}

/// 哪一步几何算用户在滚：只有用户上滑才停止跟随，布局与系统自己的移动都不算。
@Suite("滚动几何的归属")
struct ScrollAttributionTests {
    @Test("可见高度变小（键盘弹回）与越界回弹的一小步同一步报来：不是滚动")
    func viewportShrinkWithBounceBackIsNotAScroll() {
        // dev 现场（report-9，evidence-9/t37.log 22:27:40.300）：回前台，补回的行比预览矮了 38pt，视口越过底部；
        // 系统回弹把偏移往上收的同时键盘弹回。这一步被当成了用户上滑，跟随就此停止。
        let old = ScrollPosition(offset: 2350.3, contentHeight: 3005.7, visibleHeight: 574.7, belowViewport: -35.3)
        let new = ScrollPosition(offset: 2348.7, contentHeight: 3005.7, visibleHeight: 328.7, belowViewport: 212.3)
        #expect(!new.isScroll(from: old))
    }

    @Test("越过底部后系统的回弹（偏移往上收、仍在越界区内）：不是滚动")
    func bounceBackIsNotAScroll() {
        // 同一现场 22:27:40.270 的那一步。
        let old = ScrollPosition(offset: 2352.0, contentHeight: 3005.7, visibleHeight: 574.7, belowViewport: -37.0)
        let new = ScrollPosition(offset: 2350.3, contentHeight: 3005.7, visibleHeight: 574.7, belowViewport: -35.3)
        #expect(!new.isScroll(from: old))
    }

    @Test("内容与可见高度都没变时往上挪：是滚动，从底部起步（贴底时 below 可能是 -0.1）也算")
    func userDragIsAScroll() {
        let bottom = ScrollPosition(offset: 2561.0, contentHeight: 3005.7, visibleHeight: 328.7, belowViewport: -0.1)
        let up = ScrollPosition(offset: 2541.0, contentHeight: 3005.7, visibleHeight: 328.7, belowViewport: 19.9)
        #expect(up.isScroll(from: bottom))
        let further = ScrollPosition(offset: 2361.0, contentHeight: 3005.7, visibleHeight: 328.7, belowViewport: 199.9)
        #expect(further.isScroll(from: up))
        #expect(!further.atBottom)
    }

    @Test("内容增减带动的偏移不是滚动")
    func contentChangeIsNotAScroll() {
        let old = ScrollPosition(offset: 2249.0, contentHeight: 2939.7, visibleHeight: 574.7, belowViewport: 0)
        let new = ScrollPosition(offset: 2200.0, contentHeight: 3043.7, visibleHeight: 574.7, belowViewport: 153)
        #expect(!new.isScroll(from: old))
    }
}

/// 托管一屏并能拿到它的 UIKit 层级。
@MainActor
fileprivate final class ScrollHost {
    let window: UIWindow
    let controller: UIViewController

    init(_ view: some View, size: CGSize = CGSize(width: 390, height: 844)) {
        controller = UIHostingController(rootView: view)
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
    }

    isolated deinit { window.isHidden = true }

    /// 反复布局、让出运行循环，直到条件成立（上限 5 秒）。
    func settle(_ what: @autoclosure () -> String = "", sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool) async throws {
        for _ in 0..<250 {
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            if await condition() { return }
        }
        Issue.record("条件在 5 秒内没有成立：\(what())", sourceLocation: sourceLocation)
        throw CancellationError()
    }

    /// 底部让出一段（与键盘同形：安全区收窄，列表可见高度随之变小）；0 即收起。
    func shrinkViewport(by height: CGFloat) {
        controller.additionalSafeAreaInsets.bottom = height
    }

    /// 手指按上列表开始拖（滚动视图代理收到的与真实拖动同一个开头；偏移仍由测试拨动）。
    func beginDragging(_ scrollView: UIScrollView) {
        scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
    }

    /// 手指抬起，不带惯性。
    func endDragging(_ scrollView: UIScrollView) {
        var target = scrollView.contentOffset
        scrollView.delegate?.scrollViewWillEndDragging?(scrollView, withVelocity: .zero, targetContentOffset: &target)
        scrollView.delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: false)
    }

    /// 让出若干帧，不带条件。
    func frames(_ count: Int) async throws {
        for _ in 0..<count {
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 最新一行的（最末一个）格子整个落在可见区内。
    func isShowingLastRow(_ scrollView: UIScrollView, model: TranscriptModel) -> Bool {
        guard let collection = scrollView as? UICollectionView else { return isAtBottom(scrollView) }
        let sections = collection.numberOfSections
        guard sections > 0 else { return false }
        let items = collection.numberOfItems(inSection: sections - 1)
        guard items == TranscriptCells.build(model.rows).count, items > 0,
              let cell = collection.cellForItem(at: IndexPath(item: items - 1, section: sections - 1)) else { return false }
        let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        return cell.frame.minY >= visibleTop - 1 && cell.frame.maxY <= visibleBottom + 1
    }

    /// 各个格子的位置（只列高过一屏的，以及最末两格）。
    func describeCells(_ scrollView: UIScrollView) -> String {
        guard let collection = scrollView as? UICollectionView, collection.numberOfSections > 0 else { return "" }
        let section = collection.numberOfSections - 1
        let count = collection.numberOfItems(inSection: section)
        return (0..<count).compactMap { item -> String? in
            let path = IndexPath(item: item, section: section)
            guard let frame = collection.layoutAttributesForItem(at: path)?.frame else { return nil }
            guard frame.height > scrollView.bounds.height || item >= count - 2 else { return nil }
            let live = collection.cellForItem(at: path) != nil ? "显示中" : "未显示"
            return "#\(item) y=\(Int(frame.minY))…\(Int(frame.maxY)) h=\(Int(frame.height)) \(live)"
        }.joined(separator: "; ")
    }

    func describe(_ scrollView: UIScrollView) -> String {
        "offset=\(scrollView.contentOffset.y) bounds=\(scrollView.bounds.height) content=\(scrollView.contentSize.height) insets=\(scrollView.adjustedContentInset)"
    }

    func scrollView() -> UIScrollView? {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(controller.view)
    }

    func describeScrollViews() -> String {
        var out: [String] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView { out.append("\(type(of: scroll)) size=\(scroll.contentSize) bounds=\(scroll.bounds)") }
            view.subviews.forEach(walk)
        }
        walk(controller.view)
        return out.joined(separator: "; ")
    }

    func isAtBottom(_ scrollView: UIScrollView) -> Bool {
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        return visibleBottom >= scrollView.contentSize.height - 2
    }

    /// 无障碍树里的元素（SwiftUI 只在辅助功能开启时建树）。
    func elements() -> [NSObject] {
        if let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let symbol = dlsym(handle, "_AXSSetAutomationEnabled") {
            typealias SetEnabled = @convention(c) (Int32) -> Void
            unsafeBitCast(symbol, to: SetEnabled.self)(1)
        }
        var found: [NSObject] = []
        func visit(_ node: NSObject) {
            if let view = node as? UIView, view.isHidden || view.alpha == 0 { return }
            if node.isAccessibilityElement { found.append(node); return }
            let children = node.accessibilityElements?.compactMap { $0 as? NSObject }
            for child in children ?? [] { visit(child) }
            if children == nil, let view = node as? UIView { view.subviews.forEach(visit) }
        }
        visit(controller.view)
        return found
    }

    func labels() async -> [String] { elements().compactMap(\.accessibilityLabel) }

    func element(labelled label: String) async -> NSObject? {
        elements().first { $0.accessibilityLabel == label }
    }
}
