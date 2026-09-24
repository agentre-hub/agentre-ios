import AgentreDomain
import AgentreREST
import AgentreStore
import AgentreTestSupport
import AgentreUI
import Foundation
import Testing

/// 退出登录与刷新被拒是同一个收场：回到登录屏，钥匙串里的令牌与本地会话库一并清空，
/// 换账号后读不到上一个账号的任何会话行。
@MainActor
@Suite("退出登录")
struct SignOutTests {
    @Test("退出登录：令牌清掉、回到登录屏、本地库清空，冷启动重开的库里也没有上一个账号的行")
    func signOutClearsBoth() async throws {
        let directory = try TemporaryDirectory()
        let store = try await storeWithPreviousAccountRows(directory)
        let credentials = InMemoryCredentialStore(credentials: signedInCredentials)
        let session = AppSession(credentials: credentials)
        #expect(session.phase == .signedIn)

        await SignOut(session: session, store: store).run()

        #expect(session.phase == .signedOut)
        #expect(credentials.stored == nil)
        #expect(try await store.conversations().isEmpty)
        let key = ConversationKey(machineFingerprint: "mac-fingerprint-0009", conversationID: "conv-a")
        #expect(try await store.transcript(key).isEmpty)
        let reopened = try LocalConversationStore(directory: directory.url)
        #expect(try await reopened.conversations().isEmpty)
        #expect(try await reopened.transcript(key).isEmpty)
    }

    @Test("刷新被拒：经真实的令牌提供方与鉴权传输走一遍，同样回到登录屏并清空两处")
    func rejectedRefreshClearsBoth() async throws {
        let directory = try TemporaryDirectory()
        let store = try await storeWithPreviousAccountRows(directory)
        let credentials = InMemoryCredentialStore(credentials: signedInCredentials)
        let session = AppSession(credentials: credentials)
        let signOut = SignOut(session: session, store: store)
        let server = ServerAddress.production

        // 服务端：任何带令牌的请求都 401，刷新端点拒绝刷新令牌。
        let wire = FakeHTTPTransport { request in
            if request.url.path == "/v1/oauth/token/refresh" { return HTTPResponse(status: 401) }
            return HTTPResponse(status: 401)
        }
        let tokens = AccessTokenProvider(
            credentials: credentials,
            refresher: DeviceAuthClient(transport: wire, platform: "ios", version: "1", deviceName: "iPhone"),
            server: { server },
            onRejected: { await signOut.run() }
        )
        let account = AccountClient(transport: AuthorizedTransport(inner: wire, tokens: tokens))
        let model = MeModel(
            account: account, servers: InMemoryServerAddressStore(), preferences: InMemoryDisplayPreferencesStore(), signOut: signOut
        )

        await model.load()

        #expect(session.phase == .signedOut)
        #expect(credentials.stored == nil)
        #expect(try await store.conversations().isEmpty)
        let reopened = try LocalConversationStore(directory: directory.url)
        #expect(try await reopened.conversations().isEmpty)
        #expect(model.failure == .signedOut)
    }

    @Test("撤销本机：拆登录态途中另一个请求撞上 401，也不拿已撤销的刷新令牌去刷新，只登出一次")
    func revokingThisDeviceNeverRefreshes() async throws {
        let directory = try TemporaryDirectory()
        let store = try await storeWithPreviousAccountRows(directory)
        let credentials = InMemoryCredentialStore(credentials: signedInCredentials)
        let session = AppSession(credentials: credentials)
        let signOut = SignOut(session: session, store: store)
        let server = ServerAddress.production

        // 与真实服务端同形：撤销后该设备的令牌一律 401，刷新链整条作废（invalid_grant，device revoked）。
        let revoked = HitCounter()
        let wire = FakeHTTPTransport { request in
            switch request.url.path {
            case "/v1/oauth/token/revoke":
                revoked.hit()
                return HTTPResponse(status: 200, body: Data(#"{"code":0,"msg":"ok","data":{}}"#.utf8))
            case "/v1/oauth/token/refresh":
                return .oauthError("invalid_grant", status: 400)
            default:
                return revoked.value > 0 ? HTTPResponse(status: 401) : .cagoData(#"{"devices":[]}"#)
            }
        }
        let rejections = HitCounter()
        let tokens = AccessTokenProvider(
            credentials: credentials,
            refresher: DeviceAuthClient(transport: wire, platform: "ios", version: "1", deviceName: "iPhone"),
            server: { server },
            onRejected: { rejections.hit(); await signOut.run() }
        )
        signOut.tokens = tokens
        let account = AccountClient(transport: AuthorizedTransport(inner: wire, tokens: tokens))
        // 拆登录态的途中，某一屏的请求还在路上（真机上是跟随与各屏的读取），带着已撤销的令牌撞上 401。
        var teardowns = 0
        signOut.beforeClearing = {
            teardowns += 1
            guard teardowns == 1 else { return }
            _ = try? await account.devices(server: server)
        }
        let model = MeModel(
            account: account, servers: InMemoryServerAddressStore(), preferences: InMemoryDisplayPreferencesStore(), signOut: signOut
        )

        await model.revoke(thisPhone)

        #expect(await wire.requests.map(\.url.path).filter { $0 == "/v1/oauth/token/refresh" }.isEmpty)
        #expect(rejections.value == 0)
        #expect(teardowns == 1)
        #expect(session.phase == .signedOut)
        #expect(credentials.stored == nil)
        #expect(try await store.conversations().isEmpty)
    }

    @Test("本地库删行失败：上一个账号的行在本实例与冷启动重开后都读不到，令牌照样清掉")
    func clearFailureLeavesNothingReadable() async throws {
        struct ClearFailed: Error {}
        let directory = try TemporaryDirectory()
        let store = try await storeWithPreviousAccountRows(directory, clearRows: { _ in throw ClearFailed() })
        let credentials = InMemoryCredentialStore(credentials: signedInCredentials)
        let session = AppSession(credentials: credentials)

        await SignOut(session: session, store: store).run()

        #expect(session.phase == .signedOut)
        #expect(credentials.stored == nil)
        let key = ConversationKey(machineFingerprint: "mac-fingerprint-0009", conversationID: "conv-a")
        #expect(try await store.conversations().isEmpty)
        #expect(try await store.transcript(key).isEmpty)
        let reopened = try LocalConversationStore(directory: directory.url)
        #expect(try await reopened.conversations().isEmpty)
        #expect(try await reopened.transcript(key).isEmpty)
    }

    @Test("本地库清不掉时登出也不停在半路：令牌照样清掉、照样回到登录屏")
    func storeFailureStillSignsOut() async throws {
        let store = FailingConversationStore()
        let credentials = InMemoryCredentialStore(credentials: signedInCredentials)
        let session = AppSession(credentials: credentials)

        await SignOut(session: session, store: store).run()

        #expect(session.phase == .signedOut)
        #expect(credentials.stored == nil)
        #expect(await store.removeAllCalls >= 1)
    }
}

/// 跨并发域计数（伪服务端的处理闭包与令牌提供方的回调里都要记）。
private final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func hit() { lock.withLock { count += 1 } }
}
