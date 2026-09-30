import XCTest

/// 外壳（决策 23、测试决策「tab 栏可见性」）：自绘 tab 栏只在三个顶层页出现；机器详情、新建对话模态、草稿、
/// 对话，以及键盘弹起时，界面上都不存在 tab 栏元素。二级页的系统边缘右滑返回照常可用。
/// 三个顶层页各留一张截图（浅色中文、深色英文各一遍），供与稿子逐屏对照。
@MainActor
final class ShellChromeUITests: XCTestCase {
    func testShellChromeSimplifiedChineseLight() throws { try shellChrome(language: "zh-Hans", locale: "zh_CN", dark: false) }
    func testShellChromeEnglishDark() throws { try shellChrome(language: "en", locale: "en_US", dark: true) }

    private static let firstMessage = "Sketch the relay handshake"

    private func shellChrome(language: String, locale: String, dark: Bool) throws {
        continueAfterFailure = false
        let copy = Copy(language: language)
        let box = FakeAgentred()
        let server = try FakeAgentreServer(machines: [box])
        defer { server.stop() }
        let app = launch(against: server, language: language, locale: locale)
        let screen = Screen(app: app, test: self, prefix: "shell-\(language)-\(dark ? "dark" : "light")")
        signIn(app, screen, copy, server)

        // 「我」：先按这一遍的外观切好，三张顶层页截图才是这个主题。外观现在是「我」的二级页（规格「09 我」）。
        screen.tap(screen.tab(.me), "Me tab")
        screen.expect(screen.text(copy("Me", "me.account")), "account page title")
        screen.tap(screen.button(startingWith: copy("Me", "me.appearance")), "appearance row")
        screen.expectNoTabBar("the appearance page")
        let appearance = screen.button(startingWith: copy("Me", dark ? "me.appearance.dark" : "me.appearance.light"))
        screen.reveal(appearance, "appearance option")
        screen.tap(appearance, "appearance option")
        screen.expectAppearance(dark: dark, "Me after choosing the appearance")
        screen.tap(screen.back, "back from the appearance page")
        screen.expectTabBar("Me")
        screen.shot("top-level me")

        // 机器名册（顶层）→ 机器详情（二级）：tab 栏退场；边缘右滑回到名册，tab 栏回来。
        screen.tap(screen.tab(.machines), "Machines tab")
        let machineRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", FakeAgentred.boxName)).firstMatch
        screen.expect(machineRow, "roster row")
        screen.expectTabBar("the machine roster")
        screen.expectSelected(screen.tab(.machines), "Machines tab")
        screen.shot("top-level machines")
        screen.tap(machineRow, "machine row")
        screen.expect(screen.text(copy("Machines", "machines.detail.count.total")), "machine detail")
        screen.expect(screen.back, "compact back arrow")
        screen.expectNoTabBar("machine detail")
        screen.shot("machine detail without tab bar")
        screen.swipeBackFromEdge()
        screen.expectGone(screen.back, "machine detail after the edge swipe")
        screen.expect(machineRow, "roster row after the edge swipe")
        screen.expectTabBar("the machine roster after the edge swipe")

        // 消息（顶层）→ 新建对话：自带栈的模态，左上「取消」；取消即收起，tab 栏回来。
        screen.tap(screen.tab(.messages), "Messages tab")
        screen.expectTabBar("the message list")
        screen.shot("top-level messages")

        // 顶层页键盘弹起时同样没有 tab 栏：消息列表的本地搜索框（规格「01 消息」）。
        let search = screen.input(copy("Messages", "messages.search"))
        screen.tap(search, "messages search field")
        screen.expect(app.keyboards.firstMatch, "keyboard on the message list")
        screen.expectNoTabBar("the message list with the keyboard up")
        screen.shot("messages keyboard up")
        search.typeText("\n")
        screen.expectTabBar("the message list after dismissing the keyboard")

        let newConversation = screen.button(copy("NewConversation", "newconv.title"))
        screen.tap(newConversation, "new conversation")
        screen.expect(screen.cancel, "cancel on the new-conversation modal")
        screen.expect(screen.text(copy("Shell", "shell.newConversation")), "new-conversation modal title")
        screen.expectNoTabBar("the new-conversation modal")
        screen.shot("new conversation modal")
        screen.tap(screen.cancel, "cancel the new conversation")
        screen.expectGone(screen.cancel, "the new-conversation modal")
        screen.expectTabBar("the message list after cancelling")

        // 再开：选 Agent → 草稿（二级）；键盘弹起时同样没有 tab 栏。
        screen.tap(newConversation, "new conversation again")
        let agentRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", FakeAgentreServer.agentName)).firstMatch
        screen.tap(agentRow, "agent row")
        screen.expect(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", FakeAgentred.boxName)).firstMatch, "machine chip")
        screen.expectNoTabBar("the draft")
        screen.type(Self.firstMessage, into: screen.input(copy("NewConversation", "newconv.message")), "draft message field")
        screen.expect(app.keyboards.firstMatch, "keyboard on the draft")
        screen.expectNoTabBar("the draft with the keyboard up")
        screen.shot("draft keyboard up")

        // 首条发出：模态收起，这条对话在消息页的栈上打开（二级，没有 tab 栏）；边缘右滑回到消息列表。
        screen.tap(screen.button(copy("NewConversation", "newconv.send")), "send the first message")
        screen.expectOnScreen(screen.text(Self.firstMessage), "the first message in the conversation")
        screen.expectGone(screen.cancel, "the new-conversation modal after the first send")
        screen.expect(screen.back, "compact back arrow on the conversation")
        screen.expectNoTabBar("the conversation")
        screen.tap(screen.input(copy("Composer", "composer.message")), "composer field")
        screen.expect(app.keyboards.firstMatch, "keyboard on the conversation")
        screen.expectNoTabBar("the conversation with the keyboard up")
        screen.shot("conversation keyboard up")
        screen.swipeBackFromEdge()
        screen.expectGone(screen.back, "the conversation after the edge swipe")
        screen.expectTabBar("the message list after leaving the conversation")
        screen.expectSelected(screen.tab(.messages), "Messages tab")
        screen.expect(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", Self.firstMessage)).firstMatch, "the new conversation in the list")
        screen.shot("messages after the new conversation")
        XCTAssertEqual(server.read { _ in box.runs.count }, 1, "the draft dispatched exactly one runtime.run")
    }
}
