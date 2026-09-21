import AgentreDomain
import Foundation
import Testing

@MainActor
struct LoginFlowTests {
    let credentials = InMemoryCredentialStore()
    let servers = InMemoryServerAddressStore()
    let opener = RecordingOpener()
    let clock = FakeClock()

    func makeFlow(_ auth: ScriptedDeviceAuth) -> (LoginFlow, AppSession) {
        let session = AppSession(credentials: credentials)
        let clock = clock
        let flow = LoginFlow(
            session: session, deviceAuth: auth, credentials: credentials, servers: servers,
            opener: opener, sleeper: clock, now: { clock.now }
        )
        return (flow, session)
    }

    @Test("授权中：保持等待并按原间隔继续轮询，直接打开带确认码的验证地址")
    func pendingKeepsPolling() async {
        let auth = ScriptedDeviceAuth(polls: [.success(.pending), .success(.pending), .success(.denied)])
        let (flow, _) = makeFlow(auth)
        let seen = StateLog()
        auth.onPoll = { @MainActor in seen.append(flow.state) }

        await flow.signIn()

        #expect(opener.opened == [DeviceAuthorization.sample.verificationURIComplete])
        #expect(seen.states == [.awaitingApproval, .awaitingApproval, .awaitingApproval])
        #expect(auth.polledCodes == ["dev-code-1", "dev-code-1", "dev-code-1"])
        #expect(clock.sleeps == [.seconds(5), .seconds(5), .seconds(5)])
    }

    @Test("slow_down 不是收场：间隔加 5 秒后继续等")
    func slowDownWidensInterval() async {
        let auth = ScriptedDeviceAuth(polls: [.success(.slowDown), .success(.pending), .success(.slowDown), .success(.denied)])
        let (flow, _) = makeFlow(auth)

        await flow.signIn()

        #expect(clock.sleeps == [.seconds(5), .seconds(10), .seconds(10), .seconds(15)])
        #expect(auth.polledCodes.count == 4)
        #expect(flow.state == .denied)
    }

    @Test("服务端没给间隔（0）：按 RFC 8628 默认 5 秒轮询，不空转")
    func missingIntervalDefaultsToFiveSeconds() async {
        var authorization = DeviceAuthorization.sample
        authorization.interval = .zero
        let auth = ScriptedDeviceAuth(authorization: .success(authorization), polls: [.success(.pending), .success(.denied)])
        let (flow, _) = makeFlow(auth)

        await flow.signIn()

        #expect(clock.sleeps == [.seconds(5), .seconds(5)])
    }

    @Test("服务端答过期：收场为过期，不存任何令牌")
    func expiredByServer() async {
        let auth = ScriptedDeviceAuth(polls: [.success(.pending), .success(.expired)])
        let (flow, session) = makeFlow(auth)

        await flow.signIn()

        #expect(flow.state == .expired)
        #expect(credentials.stored == nil)
        #expect(session.phase == .signedOut)
    }

    @Test("本地到期先到：不再轮询，收场为过期")
    func expiredByDeadline() async {
        var authorization = DeviceAuthorization.sample
        authorization.expiresIn = .seconds(12)
        let auth = ScriptedDeviceAuth(authorization: .success(authorization), polls: [])
        let (flow, _) = makeFlow(auth)

        await flow.signIn()

        #expect(flow.state == .expired)
        #expect(auth.polledCodes.count == 2)
    }

    @Test("被拒：收场为被拒，不存任何令牌")
    func denied() async {
        let auth = ScriptedDeviceAuth(polls: [.success(.denied)])
        let (flow, session) = makeFlow(auth)

        await flow.signIn()

        #expect(flow.state == .denied)
        #expect(credentials.stored == nil)
        #expect(session.phase == .signedOut)
    }

    @Test("成功：以本设备指纹发起，令牌落进凭据库，应用进入登录态")
    func success() async throws {
        let auth = ScriptedDeviceAuth(polls: [.success(.pending), .success(.authorized(.sample, deviceID: 42))])
        let (flow, session) = makeFlow(auth)

        await flow.signIn()

        #expect(flow.state == .signedIn)
        #expect(session.phase == .signedIn)
        let fingerprint = try #require(credentials.storedFingerprint)
        #expect(auth.authorizedWith.map(\.0) == [fingerprint])
        let expectedIssuedAt = clock.now
        #expect(credentials.stored == Credentials(grant: .sample, deviceID: 42, issuedAt: expectedIssuedAt))
    }

    @Test("发起即失败：收场为失败，可重试")
    func authorizeFails() async {
        let auth = ScriptedDeviceAuth(authorization: .failure(TransportDown()), polls: [])
        let (flow, _) = makeFlow(auth)

        await flow.signIn()

        #expect(flow.state == .failed)
        #expect(opener.opened.isEmpty)
    }

    @Test("轮询传输失败：收场为失败")
    func pollFails() async {
        let auth = ScriptedDeviceAuth(polls: [.success(.pending), .failure(TransportDown())])
        let (flow, _) = makeFlow(auth)

        await flow.signIn()

        #expect(flow.state == .failed)
        #expect(credentials.stored == nil)
    }

    @Test("轮询中途网络断了一下：不是收场，到期之前继续轮询")
    func transientPollFailureKeepsPolling() async {
        let auth = ScriptedDeviceAuth(polls: [
            .success(.pending), .failure(URLError(.networkConnectionLost)), .failure(URLError(.notConnectedToInternet)),
            .success(.authorized(.sample, deviceID: 42)),
        ])
        let (flow, session) = makeFlow(auth)

        await flow.signIn()

        #expect(flow.state == .signedIn)
        #expect(session.phase == .signedIn)
        #expect(auth.polledCodes.count == 4)
    }

    @Test("网络一直不通：轮询到本地到期为止，收场为过期")
    func transientPollFailureUntilDeadline() async {
        var authorization = DeviceAuthorization.sample
        authorization.expiresIn = .seconds(12)
        let auth = ScriptedDeviceAuth(
            authorization: .success(authorization),
            polls: [.failure(URLError(.networkConnectionLost)), .failure(URLError(.timedOut))]
        )
        let (flow, _) = makeFlow(auth)

        await flow.signIn()

        #expect(flow.state == .expired)
        #expect(auth.polledCodes.count == 2)
    }

    @Test("登录后在「我」页换了服务器并登出：登录屏回到初始、显示新地址，再次登录按新地址发起")
    func signOutAfterServerChange() async {
        let auth = ScriptedDeviceAuth(polls: [.success(.authorized(.sample, deviceID: 42)), .success(.denied)])
        let (flow, session) = makeFlow(auth)
        await flow.signIn()
        #expect(flow.state == .signedIn)

        // 「我」页改地址：存下新地址，随即登出；登录流程本身没有经手。
        let dev = ServerAddress(string: "http://docker.local:8443")!
        servers.save(dev)
        session.signOut()

        #expect(flow.state == .idle)
        #expect(flow.serverAddress == dev)
        await flow.signIn()
        #expect(auth.authorizedWith.map(\.1) == [.production, dev])
        #expect(flow.state == .denied)
    }

    @Test("服务器地址默认生产；非法地址被拒，合法地址被保存并用于发起")
    func serverAddress() async {
        let auth = ScriptedDeviceAuth(polls: [.success(.denied)])
        let (flow, _) = makeFlow(auth)
        #expect(flow.serverAddress == .production)
        #expect(flow.serverAddress.url.absoluteString == "https://app.agentrehub.com")

        #expect(flow.setServerAddress("ftp://docker.local") == false)
        #expect(flow.setServerAddress("not a url") == false)
        #expect(flow.serverAddress == .production)

        #expect(flow.setServerAddress(" http://docker.local:8443/ ") == true)
        let dev = ServerAddress(string: "http://docker.local:8443")!
        #expect(flow.serverAddress == dev)
        #expect(servers.load() == dev)

        await flow.signIn()
        #expect(auth.authorizedWith.map(\.1) == [dev])
    }
}

@MainActor
final class StateLog {
    private(set) var states: [LoginFlow.State] = []
    func append(_ state: LoginFlow.State) { states.append(state) }
}
