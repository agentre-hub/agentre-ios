import XCTest

/// 各界面流程共用的起步：启动 App 指向伪服务端、走设备流登录。
@MainActor
extension XCTestCase {
    /// 经启动参数指向伪服务端：`-serverAddress` 落进 UserDefaults 的参数域，App 读服务器地址就读到它。
    /// 「我」里存下的语言与外观（手动跑过的 App 留在模拟器上）会盖过 `-AppleLanguages`：同样经参数域重置为跟随系统。
    /// 钥匙串里的登录态与本地库不随 App 清掉：经启动环境让 App 从登出状态起步。
    func launch(against server: FakeAgentreServer, language: String, locale: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-serverAddress", server.baseURL,
            "-displayLanguage", "system", "-displayAppearance", "system",
        ]
        app.launchEnvironment["AGENTRE_START_SIGNED_OUT"] = "1"
        app.launch()
        return app
    }

    /// 登录屏：当前服务器地址（启动参数给的伪服务端）与一个主操作。设备流：App 直接打开带确认码的验证地址；
    /// 浏览器取到那一页即批准，轮询换得令牌落到三标签。
    func signIn(_ app: XCUIApplication, _ screen: Screen, _ copy: Copy, _ server: FakeAgentreServer) {
        screen.expect(screen.button(copy("Login", "login.signIn")), "sign-in button")
        screen.expect(screen.text(server.baseURL), "server address from the launch argument")
        screen.shot("01 login")

        screen.tap(screen.button(copy("Login", "login.signIn")), "sign in")
        screen.expect("the browser opened the verification address with the user code", timeout: 60) {
            server.verificationPageVisits.contains(FakeAgentreServer.userCode)
        }
        screen.shot("03 verification page")
        app.activate()
        screen.expect(screen.tab(.messages), "Messages tab after sign-in", timeout: 30)
        XCTAssertFalse(server.signedInFingerprint.isEmpty, "authorize carried no device fingerprint")
        screen.shot("04 signed in")
    }
}
