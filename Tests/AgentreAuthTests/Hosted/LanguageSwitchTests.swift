@testable import Agentre
import AgentreDomain
import Foundation
import Testing

/// 「我」里切换语言：三个标签页根屏的导航栏大标题随之即时换成新语言，同屏不中英混杂；
/// 已在导航栈里的屏与用户的导航位置不因切换而丢失。
@MainActor
@Suite(.serialized)
struct LanguageSwitchTests {
    /// 每个标签页根屏导航栏上由本地化文案给出的文字：标题，以及消息页的「新对话」按钮（工具栏项的读屏标签）。
    private static let roots: [(tab: Int, copy: [(key: String, table: String)])] = [
        (0, [("messages.title", "Messages"), ("newconv.title", "NewConversation")]),
        (1, [("machines.title", "Machines")]),
        (2, [("me.title", "Me")]),
    ]

    @Test("切到 English、切回简体中文、再跟随系统：三个标签页根屏的大标题每次都即时换成那种语言；机器栈里打开着的详情仍在")
    func switchingLanguageRetitlesEveryRoot() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.signIn()
        let environment = try harness.environment()
        let screen = Screen(AppRootView(environment: environment))
        defer { screen.close() }
        let services = try await eventually("signed in") { environment.services }

        // 先以一种显式语言把三个标签页都走一遍（它们的导航栏都已建好并解析过标题），再切到另一种。
        environment.me.setLanguage(.simplifiedChinese)
        try await expectRootTitles(on: screen, language: "zh-Hans")

        // 机器栈里打开一台机器的详情，停在「我」页上切语言：切换不应把用户的导航位置清掉。
        try await screen.selectTab(1)
        try await screen.waitFor("mac-studio")
        services.router.machines = [.machine("machine-a")]
        _ = try await eventually("machine detail open") { await screen.navigationTitles().contains("mac-studio") ? true : nil }
        try await screen.selectTab(2)

        environment.me.setLanguage(.english)
        try await screen.selectTab(1)
        #expect(services.router.machines == [.machine("machine-a")])
        _ = try await eventually("machine detail still open") { await screen.navigationTitles().contains("mac-studio") ? true : nil }
        services.router.machines = []
        try await expectRootTitles(on: screen, language: "en")

        environment.me.setLanguage(.simplifiedChinese)
        try await expectRootTitles(on: screen, language: "zh-Hans")

        // 跟随系统：回到进程此刻的系统语言（测试机的首选语言），而不是停在上一次的覆盖上。
        environment.me.setLanguage(.english)
        try await expectRootTitles(on: screen, language: "en")
        environment.me.setLanguage(.system)
        let system = try #require(Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: Locale.preferredLanguages).first)
        try await expectRootTitles(on: screen, language: system)

        await environment.tearDown()
    }

    /// 逐个切到三个标签页，断言导航栏上看得见的标题与按钮恰是该语言的译文，且没有另一种语言的残留。
    private func expectRootTitles(on screen: Screen, language: String) async throws {
        let other = language == "en" ? "zh-Hans" : "en"
        for root in Self.roots {
            try await screen.selectTab(root.tab)
            for (key, table) in root.copy {
                let expected = copy(key, table: table, language: language)
                let stale = copy(key, table: table, language: other)
                #expect(expected != stale)
                do {
                    _ = try await eventually("\(key) in \(language)", seconds: 3) {
                        let titles = await screen.navigationTitles()
                        return titles.contains(expected) && !titles.contains(stale) ? true : nil
                    }
                } catch {
                    Issue.record("\(key): expected “\(expected)” (\(language)); nav bar shows \(await screen.navigationTitles())")
                }
            }
        }
    }
}
