import AgentreDomain
import Darwin
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
        let address = flow.serverAddress.url.absoluteString
        #expect(address == "https://app.agentrehub.com")

        let frame = try #require(await renderedFrame(of: address, in: LoginView(flow: flow), size: size), "屏上找不到地址")
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        let whole = (address as NSString).size(withAttributes: [.font: font])
        #expect(frame.width >= whole.width.rounded(.down), "地址排出来 \(frame.width)pt 宽，完整需要 \(whole.width)pt")
        #expect(frame.height < whole.height * 2, "默认字号下一行排下：\(frame)")
    }

    /// 屏上某段文字实际排出来的框（窗口坐标）：SwiftUI 截断的文字，无障碍标签仍是全文，框是截断后的宽度。
    func renderedFrame(of text: String, in view: some View, size: CGSize) async -> CGRect? {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled")
        else { return nil }
        unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(1)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<5 {
            controller.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        func find(_ node: NSObject) -> NSObject? {
            if node.isAccessibilityElement { return node.accessibilityLabel == text ? node : nil }
            let children = node.accessibilityElements?.compactMap { $0 as? NSObject } ?? (node as? UIView)?.subviews ?? []
            return children.lazy.compactMap(find).first
        }
        return find(controller.view).map { window.convert($0.accessibilityFrame, from: nil) }
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
