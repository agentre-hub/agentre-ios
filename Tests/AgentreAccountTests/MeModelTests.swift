import AgentreDomain
import AgentreStore
@testable import AgentreUI
import Foundation
import Testing

@MainActor
@Suite("「我」的状态")
struct MeModelTests {
    @MainActor
    struct Harness {
        let account = FakeAccountService()
        let servers: InMemoryServerAddressStore
        let preferences = InMemoryDisplayPreferencesStore()
        let credentials = InMemoryCredentialStore(credentials: signedInCredentials)
        let session: AppSession
        let model: MeModel

        init(server: ServerAddress = .production, sleeper: any Sleeping = NeverSleeper()) {
            servers = InMemoryServerAddressStore(server)
            session = AppSession(credentials: credentials)
            model = MeModel(
                account: account, servers: servers, preferences: preferences,
                signOut: SignOut(session: session, store: EmptyStore()), sleeper: sleeper
            )
        }
    }

    @Test("载入：账号信息与已授权设备，请求发往当前服务器")
    func load() async throws {
        let h = Harness()
        await h.model.load()
        #expect(h.model.profile == sampleProfile)
        #expect(h.model.devices == [thisPhone, studioMac])
        #expect(h.model.failure == nil)
        #expect(await h.account.servers == [.production])
    }

    @Test("载入失败呈现为事实并给出重试；重试成功后事实消失")
    func loadFailure() async throws {
        let h = Harness()
        await h.account.configure(profile: .failure(URLError(.notConnectedToInternet)))
        await h.model.load()
        #expect(h.model.failure == .offline)
        #expect(h.model.failure?.exit == .retry)
        await h.account.configure(profile: .success(sampleProfile))
        await h.model.load()
        #expect(h.model.failure == nil)
        #expect(h.model.profile == sampleProfile)
    }

    @Test("服务器地址默认指向生产：没存过地址时读出的就是 app.agentrehub.com")
    func defaultsToProduction() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentreAccountTests-\(UUID().uuidString)"))
        let model = MeModel(
            account: FakeAccountService(), servers: UserDefaultsServerAddressStore(defaults: defaults),
            preferences: InMemoryDisplayPreferencesStore(),
            signOut: SignOut(session: AppSession(credentials: InMemoryCredentialStore()), store: EmptyStore())
        )
        #expect(model.serverAddress == .production)
        #expect(model.serverAddress.url.absoluteString == "https://app.agentrehub.com")
    }

    @Test("改服务器地址：不合法不改；合法且不同则存下并退出登录——令牌不能发给另一台服务器")
    func editServer() async throws {
        let h = Harness()
        #expect(await h.model.setServerAddress("ftp://nope") == false)
        #expect(h.model.serverAddress == .production)
        #expect(h.session.phase == .signedIn)

        #expect(await h.model.setServerAddress("https://app.agentrehub.com/") == true)
        #expect(h.session.phase == .signedIn, "同一地址不算切换")

        #expect(await h.model.setServerAddress(" http://docker.local:8443 ") == true)
        let dev = try #require(ServerAddress(string: "http://docker.local:8443"))
        #expect(h.servers.load() == dev)
        #expect(h.model.serverAddress == dev)
        #expect(h.session.phase == .signedOut)
        #expect(h.credentials.stored == nil)
    }

    @Test("换服务器即退出登录，也就先在原来那台服务器上撤销本机（决策 22）；撤销不成照样换、照样清本地")
    func switchingServerRevokesThisDeviceOnTheOldServer() async throws {
        let h = Harness()
        #expect(await h.model.setServerAddress("http://docker.local:8443") == true)
        #expect(await h.account.revoked == [0])
        #expect(await h.account.revokedOn == [.production], "撤销发往原来那台：令牌是它签的")
        #expect(h.session.phase == .signedOut)

        let offline = Harness()
        await offline.account.configure(revokeError: URLError(.notConnectedToInternet))
        #expect(await offline.model.setServerAddress("http://docker.local:8443") == true)
        #expect(offline.servers.load() == ServerAddress(string: "http://docker.local:8443"))
        #expect(offline.session.phase == .signedOut)
        #expect(offline.credentials.stored == nil)
    }

    @Test("语言与外观：改了就存下，重开读回同一份")
    func preferences() async throws {
        let h = Harness()
        #expect(h.model.preferences == DisplayPreferences(language: .system, appearance: .system))
        h.model.setLanguage(.english)
        h.model.setAppearance(.dark)
        #expect(h.preferences.load() == DisplayPreferences(language: .english, appearance: .dark))
        let reopened = MeModel(
            account: h.account, servers: h.servers, preferences: h.preferences,
            signOut: SignOut(session: h.session, store: EmptyStore())
        )
        #expect(reopened.preferences == DisplayPreferences(language: .english, appearance: .dark))
    }

    @Test("语言与外观的持久化：UserDefaults 实现读回存下的值，没存过时跟随系统")
    func userDefaultsPreferences() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentreAccountTests-\(UUID().uuidString)"))
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        #expect(store.load() == DisplayPreferences())
        store.save(DisplayPreferences(language: .simplifiedChinese, appearance: .light))
        #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).load() == DisplayPreferences(language: .simplifiedChinese, appearance: .light))
    }

    @Test("退出登录按钮背后：先撤销本机（目标 0），再回到登录屏、令牌清空（决策 22）")
    func signOut() async throws {
        let h = Harness()
        await h.model.signOut()
        #expect(await h.account.revoked == [0])
        #expect(h.session.phase == .signedOut)
        #expect(h.credentials.stored == nil)
    }

    @Test("撤销本机迟迟不答（网络在而服务器不答，要等系统一分钟的超时）：到了期限照样清本地、回到登录屏，挂着的撤销随之撤回")
    func signOutDoesNotWaitOutAHangingRevoke() async throws {
        let h = Harness(sleeper: ImmediateSleeper())
        await h.account.holdRevokes()
        let signingOut = Task { await h.model.signOut() }
        let signedOut = await settles { h.session.phase == .signedOut }
        await h.account.releaseRevokes()
        await signingOut.value
        #expect(signedOut, "撤销挂住时没有按期限收手")
        #expect(h.credentials.stored == nil)
        #expect(await h.account.revokeAttempts == 1)
    }

    @Test("换服务器时原来那台迟迟不答：到了期限照样换地址、清本地")
    func serverSwitchDoesNotWaitOutAHangingRevoke() async throws {
        let h = Harness(sleeper: ImmediateSleeper())
        await h.account.holdRevokes()
        let switching = Task { await h.model.setServerAddress("http://docker.local:8443") }
        let signedOut = await settles { h.session.phase == .signedOut }
        await h.account.releaseRevokes()
        #expect(await switching.value)
        #expect(signedOut, "撤销挂住时没有按期限收手")
        #expect(h.servers.load() == ServerAddress(string: "http://docker.local:8443"))
    }

    @Test("退出登录在途时再点一次：不再撤销、不再登出一遍——晚到的那一遍会把此后新登录的账号一并登出")
    func secondSignOutWhileInFlightIsIgnored() async throws {
        let h = Harness()
        await h.account.holdRevokes()
        let first = Task { await h.model.signOut() }
        #expect(await settles { await h.account.revokeAttempts == 1 })
        let secondReturned = Flag()
        let second = Task { await h.model.signOut(); secondReturned.on = true }
        // 第二次要么当场返回，要么又发了一次撤销（挂住）——两者先到其一。
        _ = await settles {
            let attempts = await h.account.revokeAttempts
            return secondReturned.on || attempts > 1
        }
        await h.account.releaseRevokes()
        await first.value
        await second.value
        #expect(await h.account.revokeAttempts == 1, "第二次点按又撤销了一次")
        #expect(h.session.phase == .signedOut)
    }

    @Test("退出登录：撤销本机被拒或连不上，也照样清本地、回到登录屏——不把用户困在已登录状态")
    func signOutClearsEvenWhenRevokeFails() async throws {
        let h = Harness()
        await h.account.configure(revokeError: URLError(.notConnectedToInternet))
        await h.model.signOut()
        #expect(h.session.phase == .signedOut)
        #expect(h.credentials.stored == nil)
    }
}

@MainActor
final class Flag {
    var on = false
}

/// 什么都没有的本地库。
actor EmptyStore: ConversationStore {
    private(set) var removed = 0
    func conversations() async throws -> [SavedConversation] { [] }
    func conversation(_ key: ConversationKey) async throws -> SavedConversation? { nil }
    func transcript(_ key: ConversationKey) async throws -> [TranscriptFrame] { [] }
    func latestSeq(_ key: ConversationKey) async throws -> Int64 { 0 }
    func markRead(_ key: ConversationKey) async throws {}
    func delete(_ key: ConversationKey) async throws {}
    func removeAll() async throws { removed += 1 }
    func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
