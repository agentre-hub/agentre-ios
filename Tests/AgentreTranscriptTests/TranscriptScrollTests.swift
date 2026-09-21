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
