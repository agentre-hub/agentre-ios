@testable import Agentre
import AgentreDesign
import AgentreDomain
import AgentreUI
import Foundation
import SwiftUI
import Testing
import UIKit

/// 外壳（规格「逐屏视觉契约·全局框架」、决策 23）：自绘 tab 栏只在三个顶层页、栈空、无模态、键盘收起时出现；
/// 新建对话是自带栈的模态；各通用部件的命中区补满 44×44 且互不重叠。
@MainActor
@Suite(.serialized)
struct ShellChromeTests {
    @Test("tab 栏只在三个顶层页栈空时在：进二级页、开新建对话模态、键盘弹起时都不在，回来又在")
    func tabBarOnlyOnTopLevel() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let environment = try harness.environment()
        let key = try await environment.store.save(MachineSession(conversationID: "conv-1", title: "Seen"), via: "machine-a")
        let screen = Screen(AppRootView(environment: environment))
        defer { screen.close() }
        let services = try await eventually("signed in") { environment.services }
        try await screen.waitFor("Seen")

        for tab in 0..<3 {
            try await screen.selectTab(tab)
            #expect(await screen.hasTabBar(), "tab \(tab) root")
        }

        // 机器详情（二级页）：tab 栏整个不在界面上；退回机器名册又在。
        try await screen.selectTab(1)
        services.router.machines = [.machine("machine-a")]
        try await screen.expectTabBar(false, "machine detail")
        services.router.machines = []
        try await screen.expectTabBar(true, "back on the machine roster")

        // 消息栈上的对话。
        try await screen.selectTab(0)
        services.router.messages = [.conversation(key)]
        try await screen.expectTabBar(false, "conversation")
        services.router.messages = []
        try await screen.expectTabBar(true, "back on the message list")

        // 新建对话：模态，左上「取消」；取消即收起，回到消息列表，tab 栏回来。
        try await screen.tap(copy("newconv.title", table: "NewConversation"))
        try await screen.waitFor(copy("shell.cancel", table: "Shell"))
        #expect(services.router.newConversation == [])
        try await screen.expectTabBar(false, "new-conversation modal")
        try await screen.tap(copy("shell.cancel", table: "Shell"))
        _ = try await eventually("modal dismissed") { services.router.newConversation == nil ? true : nil }
        try await screen.expectTabBar(true, "after cancelling the modal")

        // 顶层页上键盘弹起：tab 栏不从键盘后面透出；收起后回来。
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        try await screen.expectTabBar(false, "keyboard up")
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try await screen.expectTabBar(true, "keyboard down")
        await environment.tearDown()
    }

    @Test("tab 栏：三枚按钮各补满 44×44、互不重叠；点哪枚就切到哪页并标为选中")
    func tabBarHitTargets() async throws {
        let collector = HitTargetCollector()
        let selection = SelectionBox()
        let screen = Screen(
            ShellHost(selection: selection)
                .environment(\.hitTargetCollector, collector)
        )
        defer { screen.close() }
        try await screen.waitFor("messages page")
        try expectHitTargets(collector, count: 3)
        try await screen.selectTab(2)
        try await screen.waitFor("me page")
        #expect(selection.tab == .me)
        #expect(await !screen.labels().contains("messages page"), "the hidden tab stayed on screen")
    }

    @Test("通用部件：顶层标题的行内动作、紧凑导航栏的返回与动作、模态的取消、分组卡片的每一行，都补满 44×44 且互不重叠")
    func partsHitTargets() async throws {
        let collector = HitTargetCollector()
        var tapped: [String] = []
        let screen = Screen(
            VStack(spacing: 0) {
                Color.clear.frame(height: 1)
                    .topLevelHeader(Text(verbatim: "Title")) {
                        ChromeIconButton(.listFilter, label: Text(verbatim: "Filter")) { tapped.append("filter") }
                        ChromeIconButton(.squarePen, label: Text(verbatim: "New")) { tapped.append("new") }
                    }
                CompactNavigationBar(title: Text(verbatim: "Detail"), onBack: { tapped.append("back") }) {
                    ChromeIconButton(.info, label: Text(verbatim: "Info"), size: 21) { tapped.append("info") }
                }
                ModalNavigationBar(title: Text(verbatim: "Modal"), onCancel: { tapped.append("cancel") })
                GroupedSection {
                    GroupedRow(.shieldCheck, title: Text(verbatim: "Permission"), value: Text(verbatim: "default")) { tapped.append("row1") }
                    GroupedRow(.cpu, title: Text(verbatim: "Model"), value: Text(verbatim: "opus"), monoValue: true) { tapped.append("row2") }
                    GroupedRow(.trash2, title: Text(verbatim: "Delete"), role: .destructive) { tapped.append("row3") }
                }
                .padding(.horizontal, 18)
                Spacer()
            }
            .background(.token(.bg))
            .environment(\.hitTargetCollector, collector)
        )
        defer { screen.close() }
        try await screen.waitFor("Permission")
        try expectHitTargets(collector, count: 8)
        #expect(await screen.navigationTitles().contains("Title"))
        #expect(await screen.navigationTitles().contains("Detail"))
        try await screen.tap(copy("shell.back", table: "Shell"))
        try await screen.tap("Model", exact: false)
        #expect(tapped == ["back", "row2"])
    }

    @Test("紧凑导航栏的返回退回上一屏（系统导航栏已隐去，返回箭头是自己画的）")
    func compactBackPops() async throws {
        let path = PathBox()
        path.path = ["detail"]
        let screen = Screen(PushedHost(box: path))
        defer { screen.close() }
        try await screen.waitFor("pushed page")
        #expect(await screen.navigationTitles().contains("Pushed"))
        try await screen.tap(copy("shell.back", table: "Shell"))
        _ = try await eventually("popped") { path.path.isEmpty ? true : nil }
        try await screen.waitFor("root page")
    }

    @Test("底部面板高度贴合内容：两行分组卡片的面板远矮于半屏")
    func fittedSheetHugsContent() async throws {
        let screen = Screen(SheetHost())
        defer { screen.close() }
        try await screen.waitFor("Model")
        let sheet = try await eventually("sheet presented") { screen.window.rootViewController?.presentedViewController }
        let height = try await eventually("sheet laid out") { () -> CGFloat? in
            let frame = sheet.view.frame
            return frame.height > 0 ? frame.height : nil
        }
        let window = screen.window.bounds.height
        #expect(height < window * 0.35, "sheet \(height) of \(window)")
        #expect(height > 100, "sheet \(height) cut its content")
    }

    @Test("底部面板的内容比屏幕还高时可以滚动：末尾的行滚得到，不被裁在屏幕下沿之外")
    func fittedSheetScrollsOverflow() async throws {
        let screen = Screen(SheetHost(rows: 40))
        defer { screen.close() }
        let sheet = try await eventually("sheet presented") { screen.window.rootViewController?.presentedViewController }
        let scroll = try await eventually("sheet scrolls its content") { () -> UIScrollView? in
            sheet.view.layoutIfNeeded()
            return descendants(of: sheet.view).compactMap { $0 as? UIScrollView }
                .first { $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height + 1 }
        }
        #expect(scroll.frame.maxY <= sheet.view.bounds.maxY + 0.5, "scroll view \(scroll.frame) past the sheet \(sheet.view.bounds)")
    }

    @Test("搜索框：可点区域至少 44pt 高，占位按界面语言，输入即写回绑定")
    func searchField() async throws {
        let box = TextBox()
        let screen = Screen(SearchHost(box: box).environment(\.locale, Locale(identifier: "zh-Hans")))
        defer { screen.close() }
        let field = try await eventually("text field") { await screen.textFields().first }
        #expect(field.bounds.height >= minimumHitTargetSide)
        #expect(field.placeholder == copy("messages.title", table: "Messages", language: "zh-Hans"))
        field.text = "relay"
        field.sendActions(for: .editingChanged)
        #expect(box.text == "relay")
    }

    private func expectHitTargets(_ collector: HitTargetCollector, count: Int, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let frames = Array(collector.frames.values)
        #expect(frames.count == count, "placed \(count) tappable parts, discovered \(frames)", sourceLocation: sourceLocation)
        for frame in frames {
            #expect(frame.width >= minimumHitTargetSide - 0.5 && frame.height >= minimumHitTargetSide - 0.5, "\(frame)", sourceLocation: sourceLocation)
        }
        for i in frames.indices {
            for j in frames.indices where j > i {
                let overlap = frames[i].intersection(frames[j])
                #expect(overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5, "\(frames[i]) overlaps \(frames[j])", sourceLocation: sourceLocation)
            }
        }
    }
}

@MainActor
@Observable
private final class SelectionBox {
    var tab: ShellTab = .messages
}

private struct ShellHost: View {
    @Bindable var selection: SelectionBox

    var body: some View {
        ShellView(selection: $selection.tab, showsTabBar: true) {
            Text(verbatim: "messages page")
        } machines: {
            Text(verbatim: "machines page")
        } me: {
            Text(verbatim: "me page")
        }
    }
}

@MainActor
@Observable
private final class PathBox {
    var path: [String] = []
}

private struct PushedHost: View {
    @Bindable var box: PathBox

    var body: some View {
        NavigationStack(path: $box.path) {
            Text(verbatim: "root page")
                .navigationDestination(for: String.self) { _ in
                    Text(verbatim: "pushed page")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .compactNavigationBar(title: Text(verbatim: "Pushed"))
                }
        }
    }
}

private struct SheetHost: View {
    /// 0 时是稿子那样的两行；给出行数时铺这么多行，比屏幕还高。
    var rows = 0
    @State private var presented = true

    var body: some View {
        Color.clear
            .fittedSheet(isPresented: $presented) {
                GroupedSection(style: .sheet) {
                    if rows == 0 {
                        GroupedRow(.shieldCheck, title: Text(verbatim: "Permission"), value: Text(verbatim: "default")) {}
                        GroupedRow(.cpu, title: Text(verbatim: "Model"), value: Text(verbatim: "opus"), monoValue: true) {}
                    } else {
                        ForEach(0..<rows, id: \.self) { index in
                            GroupedRow(.cpu, title: Text(verbatim: "Model \(index)")) {}
                        }
                    }
                }
            }
    }
}

private func descendants(of view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

@MainActor
@Observable
private final class TextBox {
    var text = ""
}

private struct SearchHost: View {
    @Bindable var box: TextBox

    var body: some View {
        VStack {
            SearchField(text: $box.text, placeholder: "messages.title", table: "Messages")
            Spacer()
        }
        .padding()
    }
}
