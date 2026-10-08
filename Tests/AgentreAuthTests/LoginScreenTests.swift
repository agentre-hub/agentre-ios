import AgentreDesign
import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import SwiftUI
import Testing
import UIKit

/// 登录屏与三标签骨架的视图层断言：逐屏命中区，以及设备流成功后落到三标签骨架。
@MainActor
struct LoginScreenTests {
    let credentials = InMemoryCredentialStore()
    let clock = FakeClock()

    func makeFlow(_ auth: ScriptedDeviceAuth, session: AppSession) -> LoginFlow {
        let clock = clock
        return LoginFlow(
            session: session, deviceAuth: auth, credentials: credentials, servers: InMemoryServerAddressStore(),
            opener: RecordingOpener(), sleeper: clock, now: { clock.now }
        )
    }

    func root(session: AppSession, flow: LoginFlow) -> some View {
        RootView(session: session) {
            LoginView(flow: flow)
        } shell: {
            ShellView { Color.clear } machines: { Color.clear } me: { Color.clear }
        }
    }

    static func text(_ key: String, _ table: String) -> String {
        AgentreUIResources.bundle.localizedString(forKey: key, value: nil, table: table)
    }

    @Test("登录屏：初始、失败收场、改地址三种状态下命中区都补满且互不重叠")
    func loginHitTargets() async throws {
        let session = AppSession(credentials: credentials)
        let flow = makeFlow(ScriptedDeviceAuth(authorization: .failure(TransportDown()), polls: []), session: session)

        let idle = await hitTargetReport(of: LoginView(flow: flow))
        #expect(idle.targets.count == 2, "改地址 + 登录：\(idle.targets)")
        #expect(idle.violations.isEmpty, "\(idle.violations)")

        await flow.signIn()
        #expect(flow.state == .failed)
        try await assertHitTargets(LoginView(flow: flow))

        let editing = await hitTargetReport(of: LoginView(flow: flow, isEditingServer: true))
        #expect(editing.targets.count >= 3, "地址输入框 + 取消 + 保存：\(editing.targets)")
        #expect(editing.violations.isEmpty, "\(editing.violations)")
    }

    @Test("登录屏：默认字号下服务器地址一行完整排下，不被截断", arguments: [CGSize(width: 402, height: 874), CGSize(width: 390, height: 844)])
    func serverAddressIsWhole(screen size: CGSize) async throws {
        let session = AppSession(credentials: credentials)
        let flow = makeFlow(ScriptedDeviceAuth(authorization: .failure(TransportDown()), polls: []), session: session)
        let address = flow.serverAddress.hostOnly
        #expect(address == "app.agentrehub.com")

        // 服务器行整行是一个按钮（规格「07 登录」：点开即改），无障碍框是这一整行、不只是文字本身；
        // 宽度仍须够放下完整地址，高度则以一行的命中区为界——真要折成两行会远超它。
        let frame = try #require(await HostedScreen(LoginView(flow: flow), size: size).frame(of: address), "屏上找不到地址")
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        let whole = (address as NSString).size(withAttributes: [.font: font])
        #expect(frame.width >= whole.width.rounded(.down), "地址排出来 \(frame.width)pt 宽，完整需要 \(whole.width)pt")
        #expect(frame.height < minimumHitTargetSide * 1.5, "默认字号下一行排下：\(frame)")
    }

    @Test("完全离线：登录屏如实说这台设备没有联网、登录点不动；上一次的失败不读作连不上服务器")
    func offlineLogin() async throws {
        let session = AppSession(credentials: credentials)
        let flow = makeFlow(ScriptedDeviceAuth(authorization: .failure(TransportDown()), polls: []), session: session)
        let signIn = Self.text("login.signIn", "Login")
        let offline = Self.text("login.deviceOffline", "Login")

        let online = HostedScreen(LoginView(flow: flow))
        #expect(await !online.labels().contains(offline))
        #expect(await !online.disabledLabels().contains(signIn))

        let idle = HostedScreen(LoginView(flow: flow).environment(\.isOffline, true))
        #expect(await idle.labels().contains(offline))
        #expect(await idle.disabledLabels().contains(signIn))

        await flow.signIn()
        #expect(flow.state == .failed)
        let failed = HostedScreen(LoginView(flow: flow).environment(\.isOffline, true))
        let labels = await failed.labels()
        #expect(labels.contains(offline))
        #expect(!labels.contains(Self.text("login.failed", "Login")))
        #expect(await failed.disabledLabels().contains(Self.text("login.signIn.again", "Login")))
    }

    @Test("App 内选的语言与系统不同、再切回：改地址框的占位与读屏标签随之换成那种语言，不停在系统语言或上一种语言")
    func addressFieldFollowsInAppLanguage() async throws {
        let session = AppSession(credentials: credentials)
        let flow = makeFlow(ScriptedDeviceAuth(authorization: .failure(TransportDown()), polls: []), session: session)
        let mismatches = await inAppLanguageMismatches(
            of: LoginView(flow: flow, isEditingServer: true), bundle: AgentreUIResources.bundle, copy: [("login.server", "Login")]
        )
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test("三标签骨架：标签栏三个目的地的命中区补满且互不重叠")
    func shellHitTargets() async throws {
        let report = await hitTargetReport(of: ShellView { Color.clear } machines: { Color.clear } me: { Color.clear })
        #expect(report.targets.count == 3, "\(report.targets)")
        #expect(report.violations.isEmpty, "\(report.violations)")
    }

    @Test("设备流成功：从登录屏落到三标签骨架（消息 / 机器 / 我）")
    func successLandsOnShell() async throws {
        let session = AppSession(credentials: credentials)
        let flow = makeFlow(ScriptedDeviceAuth(polls: [.success(.pending), .success(.authorized(.sample, deviceID: 1))]), session: session)
        let host = HostedScreen(root(session: session, flow: flow))

        let signIn = Self.text("login.signIn", "Login")
        #expect(await host.labels().contains(signIn))

        await flow.signIn()

        let labels = await host.labels()
        #expect(!labels.contains(signIn))
        for key in ["shell.tab.messages", "shell.tab.machines", "shell.tab.me"] {
            #expect(labels.contains(Self.text(key, "Shell")), "\(key) 不在 \(labels)")
        }
    }

    @Test("冷启动已有凭据：直接是三标签骨架")
    func restoredSessionShowsShell() async {
        let signedIn = InMemoryCredentialStore(credentials: Credentials(grant: .sample, deviceID: 1, issuedAt: .now))
        let session = AppSession(credentials: signedIn)
        let host = HostedScreen(root(session: session, flow: makeFlow(ScriptedDeviceAuth(polls: []), session: session)))

        let labels = await host.labels()
        #expect(labels.contains(Self.text("shell.tab.me", "Shell")))
        #expect(!labels.contains(Self.text("login.signIn", "Login")))
    }
}
