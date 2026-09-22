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
        try await host.settle { !model.follow.isFollowing }

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
        try await host.settle { !model.follow.isFollowing }
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

    /// 打开 `rows` 句的转录，等它在底部、在跟随。
    private func openAtBottom(rows count: Int) async throws -> (TranscriptModel, ScrollHost, UIScrollView) {
        let frames = (1...count).map { stored(decoder, Int64($0), .userMessage("第 \($0) 句")) }
        let model = TranscriptModel(
            conversation: SavedConversation(key: conversationKey, lifecycleState: "idle"),
            store: FakeStore(frames), relay: FakeRelay(), decoder: decoder
        )
        let host = ScrollHost(TranscriptView(model: model, agentName: "Claude Code"))
        try await host.settle { model.rows.count == count }
        try await host.settle { host.scrollView() != nil }
        let scrollView = try #require(host.scrollView(), "转录底下没有 UIScrollView：\(host.describeScrollViews())")
        try await host.settle { host.isAtBottom(scrollView) }
        #expect(model.follow.isFollowing)
        return (model, host, scrollView)
    }

    func text(_ key: String) -> String {
        AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Conversation")
    }
}

/// 托管一屏并能拿到它的 UIKit 层级。
@MainActor
fileprivate final class ScrollHost {
    let window: UIWindow
    let controller: UIViewController

    init(_ view: some View) {
        controller = UIHostingController(rootView: view)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
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

    /// 让出若干帧，不带条件。
    func frames(_ count: Int) async throws {
        for _ in 0..<count {
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 最新一行的格子整个落在可见区内。
    func isShowingLastRow(_ scrollView: UIScrollView, model: TranscriptModel) -> Bool {
        guard let collection = scrollView as? UICollectionView else { return isAtBottom(scrollView) }
        let sections = collection.numberOfSections
        guard sections > 0 else { return false }
        let items = collection.numberOfItems(inSection: sections - 1)
        guard items == model.rows.count, items > 0,
              let cell = collection.cellForItem(at: IndexPath(item: items - 1, section: sections - 1)) else { return false }
        let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        return cell.frame.minY >= visibleTop - 1 && cell.frame.maxY <= visibleBottom + 1
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
