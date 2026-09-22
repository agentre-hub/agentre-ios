import XCTest

/// 主线界面流程：真实构建的 Agentre 对着本测试进程里的伪服务端与伪中继（127.0.0.1、端口由系统分配）。
///
/// 登录（设备流）→ 「我」里切外观 → 机器 → 机器详情保存到手机 → 消息列表 → 新建对话并发出 → 审批 Allow Once
/// → 两轮之间切权限模式后再发一句 → 挂起回前台、打开着的对话屏续上 → 撤销本机回到登录屏。
/// 简体中文 × 英文、浅色 × 深色四种组合各跑一遍；每步断言屏上可见的结果并留截图（xcresult 附件）。
@MainActor
final class MainlineUITests: XCTestCase {
    enum Appearance: String {
        case light, dark
    }

    func testMainlineSimplifiedChineseLight() throws { try mainline(language: "zh-Hans", locale: "zh_CN", appearance: .light) }
    func testMainlineSimplifiedChineseDark() throws { try mainline(language: "zh-Hans", locale: "zh_CN", appearance: .dark) }
    func testMainlineEnglishLight() throws { try mainline(language: "en", locale: "en_US", appearance: .light) }
    func testMainlineEnglishDark() throws { try mainline(language: "en", locale: "en_US", appearance: .dark) }

    private static let savedTitle = "Fix the flaky build"
    private static let savedReply = "The cache key ignores the lockfile."
    private static let firstMessage = "List the files here"
    private static let command = "ls"
    private static let commandOutput = "README.md\nsrc"
    private static let firstReply = "There are two entries: README.md and src."
    private static let secondMessage = "Check the build again"
    private static let secondReply = "The build is green now."

    private func mainline(language: String, locale: String, appearance: Appearance) throws {
        continueAfterFailure = false
        let copy = Copy(language: language)
        let box = FakeAgentred()
        let server = try FakeAgentreServer(machines: [box])
        defer { server.stop() }
        server.perform { _ in
            box.seed(
                conversationID: "desktop-conv-1", peerFingerprint: "fp-old-desktop", title: Self.savedTitle,
                cwd: FakeAgentreServer.workingDirectory, history: [("Why is CI flaky?", Self.savedReply)]
            )
            box.plan(
                .askPermission(command: Self.command, output: Self.commandOutput, reply: Self.firstReply),
                .hold
            )
        }

        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        let screen = Screen(app: app, test: self, prefix: "\(language)-\(appearance.rawValue)")
        let dark = appearance == .dark
        signOutLeftover(screen, copy)

        // 登录屏：默认或上次的地址，改成伪服务端。
        screen.expect(screen.button(copy("Login", "login.signIn")), "sign-in button")
        screen.shot("01 login")
        screen.tap(screen.button(copy("Login", "login.server.edit")), "change server")
        let field = screen.input(copy("Login", "login.server"))
        screen.type(server.baseURL, into: field, "server address field", replacing: true)
        screen.tap(screen.button(copy("Login", "login.server.save")), "save server")
        screen.expect(screen.text(server.baseURL), "server address shown after saving")
        screen.shot("02 server changed")

        // 设备流：App 直接打开带确认码的验证地址；浏览器取到那一页即批准，轮询换得令牌落到三标签。
        screen.tap(screen.button(copy("Login", "login.signIn")), "sign in")
        screen.expect("the browser opened the verification address with the user code", timeout: 60) {
            server.verificationPageVisits.contains(FakeAgentreServer.userCode)
        }
        screen.shot("03 verification page")
        app.activate()
        screen.expect(screen.tab(copy("Shell", "shell.tab.messages")), "Messages tab after sign-in", timeout: 30)
        XCTAssertFalse(server.signedInFingerprint.isEmpty, "authorize carried no device fingerprint")
        screen.shot("04 signed in")

        // 「我」：账号、本机、外观（App 自己的外观设置）。
        screen.tap(screen.tab(copy("Shell", "shell.tab.me")), "Me tab")
        screen.expect(screen.text("UI Tester"), "account name")
        screen.expect(screen.text(copy("Me", "me.devices.thisDevice")), "this-device label")
        let option = screen.button(startingWith: copy("Me", dark ? "me.appearance.dark" : "me.appearance.light"))
        screen.reveal(option, "appearance option")
        screen.tap(option, "appearance option")
        screen.expectSelected(option, "appearance option")
        screen.expectAppearance(dark: dark, "Me after choosing the appearance")
        screen.shot("05 me appearance")

        // 机器名册 → 机器详情：三个计数、别处发起的那条会话，保存到手机。
        screen.tap(screen.tab(copy("Shell", "shell.tab.machines")), "Machines tab")
        let machineRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", FakeAgentred.boxName)).firstMatch
        screen.expect(machineRow, "roster row for \(FakeAgentred.boxName)")
        screen.expect(screen.text(copy("Machines", "machines.online")), "online state")
        screen.shot("06 machines")
        screen.tap(machineRow, "machine row")
        screen.expect(screen.text(copy("Machines", "machines.detail.count.total")), "total count")
        screen.expect(screen.text(Self.savedTitle), "the machine's conversation")
        screen.shot("07 machine detail")
        screen.tap(screen.button(copy("Machines", "machines.detail.save")), "save to phone")
        screen.expect(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", copy("Machines", "machines.detail.saved"))).firstMatch,
                      "row marked as on this phone")
        screen.shot("08 saved to phone")

        // 消息列表读本地库：刚保存的那条在。
        screen.tap(screen.tab(copy("Shell", "shell.tab.messages")), "Messages tab")
        screen.expect(screen.text(Self.savedTitle), "saved conversation in the message list")
        screen.expectAppearance(dark: dark, "message list")
        screen.shot("09 messages")

        // 新建对话：选 Agent（每行给出解析结果）→ 草稿（机器 chip）→ 发出第一条。
        screen.tap(screen.button(copy("NewConversation", "newconv.title")), "new conversation")
        let agentRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", FakeAgentreServer.agentName)).firstMatch
        screen.expect(agentRow, "agent row")
        screen.expect(screen.text(containing: FakeAgentred.boxName), "where the agent currently runs")
        screen.shot("10 pick agent")
        screen.tap(agentRow, "agent row")
        screen.expect(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", FakeAgentred.boxName)).firstMatch, "machine chip")
        screen.type(Self.firstMessage, into: screen.input(copy("NewConversation", "newconv.message")), "draft message field")
        screen.shot("11 draft")
        screen.tap(screen.button(copy("NewConversation", "newconv.send")), "send first message")

        // 转录：用户气泡，内联审批卡（工具名、命令），三枚处置同一行、右对齐。
        screen.expectOnScreen(screen.text(Self.firstMessage), "the first message in the transcript")
        screen.expect(screen.text(Self.command), "the command on the approval card")
        let reject = screen.button(copy("Cards", "permission.reject"))
        let forSession = screen.button(copy("Cards", "permission.allowForSession"))
        let once = screen.button(copy("Cards", "permission.allowOnce"))
        for (element, name) in [(reject, "Reject"), (forSession, "Allow for Session"), (once, "Allow Once")] {
            screen.expect(element, "approval button \(name)")
        }
        screen.shot("12 approval card")
        assertOneRightAlignedRow([reject, forSession, once], in: app, screen)
        XCTAssertEqual(server.read { _ in box.runs.count }, 1, "the draft dispatched exactly one runtime.run")

        screen.tap(once, "allow once")
        screen.expect(screen.text(copy("Cards", "permission.allowed")), "card settled as allowed")
        screen.expect(screen.text(Self.firstReply), "the agent's reply after the command ran")
        let reply = server.read { _ in box.permissionReplies.last }
        XCTAssertEqual(reply?.allow, true)
        XCTAssertEqual(reply?.alwaysAllowSession, false)
        screen.expectGone(screen.button(copy("Composer", "composer.stop")), "stop button once the turn ended")
        screen.shot("13 allowed")

        // 两轮之间切权限模式：只改本机当前档，不报「没有改成」；下一轮 runtime.run 带上它。
        screen.tap(screen.button(copy("Composer", "composer.permissionMode")), "permission mode")
        let plan = screen.button(startingWith: "plan")
        screen.expect(plan, "plan mode option")
        screen.expectSelected(screen.button(startingWith: "default"), "default mode (the executor's default)")
        screen.tap(plan, "plan mode")
        screen.expectSelected(plan, "plan mode")
        XCTAssertFalse(screen.text(copy("Composer", "composer.changeFailed")).exists, "switching between turns reported a failure")
        screen.shot("14 permission mode")
        screen.dismissSheet(grabbing: plan)
        screen.expectGone(plan, "permission panel")

        screen.type(Self.secondMessage, into: screen.input(copy("Composer", "composer.message")), "composer field")
        screen.tap(screen.button(copy("Composer", "composer.send")), "send second message")
        screen.expectOnScreen(screen.text(Self.secondMessage), "the second message in the transcript")
        screen.expect("the second runtime.run carried the plan mode") {
            server.read { _ in box.runs.count == 2 && box.runs.last?.permissionMode == "plan" }
        }
        XCTAssertTrue(server.read { _ in box.permissionModeCalls.isEmpty }, "switching between turns called runtime.setPermissionMode")
        screen.shot("15 second message")

        // 挂起回前台：进了后台之后服务端判死通往机器的通道（空载荷帧）、连接也断了，这一轮在机器上跑完，
        // 帧只落在机器上、一帧也没推过来；回到前台后打开着的对话屏续上，刚发的那句仍在屏上。
        // 模拟器上 App 进后台后未必马上被系统挂起，所以断连由伪服务端做，不等挂起。
        let upgradesBefore = server.read { $0.relay.upgrades }
        XCUIDevice.shared.press(.home)
        screen.expect("the app left the foreground") {
            [.runningBackground, .runningBackgroundSuspended].contains(app.state)
        }
        server.perform { server in
            server.relay.closeChannels(to: box)
            server.relay.dropAll()
            box.completeHeldTurn(reply: Self.secondReply)
        }
        screen.shot("16 in background")
        app.activate()
        screen.expectOnScreen(screen.text(Self.secondReply), "the reply produced while in the background, on the open conversation")
        screen.expectOnScreen(screen.text(Self.secondMessage), "the just-sent message after returning to the foreground")
        XCTAssertGreaterThan(server.read { $0.relay.upgrades }, upgradesBefore, "the relay was not redialled")
        screen.expectAppearance(dark: dark, "conversation after returning to the foreground")
        screen.shot("17 foreground resumed")

        // 撤销本机 → 回到登录屏。先退回消息列表：键盘随对话屏收起，标签栏才露出来。
        screen.tap(app.navigationBars.buttons["BackButton"], "back to the message list")
        screen.tap(screen.tab(copy("Shell", "shell.tab.me")), "Me tab")
        let revoke = screen.button(copy("Me", "me.devices.revoke"))
        screen.reveal(revoke, "revoke this device")
        screen.tap(revoke, "revoke this device")
        // 确认弹在锚着那一行的气泡里，按钮与行上的同名。
        let confirm = app.popovers.buttons.matching(NSPredicate(format: "label == %@", copy("Me", "me.devices.revoke"))).firstMatch
        screen.expect(confirm, "revoke confirmation")
        screen.shot("18 revoke confirmation")
        screen.tap(confirm, "confirm revoke")
        screen.expect(screen.button(copy("Login", "login.signIn")), "login screen after revoking")
        XCTAssertEqual(server.revoked, [FakeAgentreServer.phoneDeviceID])
        screen.expectAppearance(dark: dark, "login screen after revoking")
        screen.shot("19 signed out")

        XCTAssertEqual(server.unhandledRequests, [], "the app called REST endpoints the fake server does not know")
        XCTAssertEqual(server.read { _ in box.unhandledMethods }, [], "the app called wire methods the fake agentred does not answer")
    }

    /// 上一次跑到一半留下的登录态（钥匙串在模拟器上不随 App 清掉）：经「我」里的退出登录回到登录屏。
    private func signOutLeftover(_ screen: Screen, _ copy: Copy) {
        let me = screen.tab(copy("Shell", "shell.tab.me"))
        let signIn = screen.button(copy("Login", "login.signIn"))
        screen.expect("the app settled on the login screen or a signed-in shell") { signIn.exists || me.exists }
        guard !signIn.exists else { return }
        screen.tap(me, "Me tab (leftover session)")
        let signOut = screen.button(copy("Me", "me.signOut"))
        screen.reveal(signOut, "sign out (leftover session)")
        screen.tap(signOut, "sign out (leftover session)")
        screen.expect(signIn, "login screen after signing out the leftover session")
    }

    /// 三枚处置同处一行（竖直中线对齐）、按次序从左到右互不重叠，且整行贴着卡片右缘（最右一枚靠近屏幕右边）。
    private func assertOneRightAlignedRow(_ buttons: [XCUIElement], in app: XCUIApplication, _ screen: Screen,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let frames = buttons.map(\.frame)
        let width = app.windows.firstMatch.frame.width
        let midYs = frames.map(\.midY)
        let sameRow = (midYs.max()! - midYs.min()!) < 1
        let ordered = zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX }
        let rightAligned = frames.last!.maxX > width * 0.85
        if !(sameRow && ordered && rightAligned) {
            screen.shot("FAILED approval buttons not one right-aligned row")
            XCTFail("\(screen.prefix): approval buttons are not one right-aligned row: \(frames)", file: file, line: line)
        }
    }
}
