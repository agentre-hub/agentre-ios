import AgentreDomain
import AgentreREST
import AgentreTestSupport
import Foundation
import Testing

/// 刷新令牌的伪服务端：每次刷新都挂起，直到测试放行，以便让并发调用方全部撞进同一次刷新。
actor GatedRefresher: TokenRefreshing {
    private(set) var calls: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private let outcome: Result<TokenGrant, AuthError>

    init(outcome: Result<TokenGrant, AuthError>) { self.outcome = outcome }

    func refresh(refreshToken: String, server: ServerAddress) async throws -> TokenGrant {
        calls.append(refreshToken)
        if !open { await withCheckedContinuation { waiters.append($0) } }
        return try outcome.get()
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    /// 等到有刷新挂起（有上限，实现不刷新时也不会卡死），再多让出几轮后放行。
    nonisolated func settle() async {
        for _ in 0..<1_000 where await waiting == 0 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        await release()
    }

    var waiting: Int { waiters.count }
}

final class RejectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func hit() { lock.withLock { count += 1 } }
}

struct TokenRefreshTests {
    static let old = Credentials(accessToken: "old-at", refreshToken: "old-rt", accessTokenExpiresAt: .distantPast, refreshTokenExpiresAt: .distantFuture, deviceID: 9)
    static let fresh = TokenGrant(accessToken: "new-at", refreshToken: "new-rt", expiresIn: .seconds(900), refreshExpiresIn: .seconds(86_400))

    @Test("并发的五个调用方撞上同一枚过期令牌：只刷新一次，全部拿到新令牌，新凭据落库且设备不变")
    func refreshIsSingleFlight() async throws {
        let store = InMemoryCredentialStore(credentials: Self.old)
        let refresher = GatedRefresher(outcome: .success(Self.fresh))
        let provider = AccessTokenProvider(credentials: store, refresher: refresher, server: { .production }, onRejected: {})

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask { try await provider.refreshedToken(replacing: "old-at") }
            }
            // 让全部调用方都有机会撞进刷新，再放行。
            await refresher.settle()
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(tokens == Array(repeating: "new-at", count: 5))
        #expect(await refresher.calls == ["old-rt"])
        #expect(store.stored?.accessToken == "new-at")
        #expect(store.stored?.refreshToken == "new-rt")
        #expect(store.stored?.deviceID == 9)
        #expect(try await provider.accessToken() == "new-at")
    }

    @Test("别人已经刷新过：拿着旧令牌来的调用方直接得到当前令牌，不再刷新")
    func alreadyRefreshed() async throws {
        let store = InMemoryCredentialStore(credentials: Self.old)
        let refresher = GatedRefresher(outcome: .success(Self.fresh))
        await refresher.release()
        let provider = AccessTokenProvider(credentials: store, refresher: refresher, server: { .production }, onRejected: {})

        _ = try await provider.refreshedToken(replacing: "old-at")
        let again = try await provider.refreshedToken(replacing: "old-at")

        #expect(again == "new-at")
        #expect(await refresher.calls.count == 1)
    }

    @Test("刷新被拒：只登出一次，所有调用方都得到 refreshRejected")
    func rejectedSignsOutOnce() async throws {
        let store = InMemoryCredentialStore(credentials: Self.old)
        let refresher = GatedRefresher(outcome: .failure(.refreshRejected))
        let rejections = RejectionCounter()
        let provider = AccessTokenProvider(credentials: store, refresher: refresher, server: { .production }, onRejected: { rejections.hit() })

        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do { _ = try await provider.refreshedToken(replacing: "old-at"); return false }
                    catch { return error as? AuthError == .refreshRejected }
                }
            }
            await refresher.settle()
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(outcomes == [true, true, true])
        #expect(await refresher.calls.count == 1)
        #expect(rejections.value == 1)
    }

    @Test("刷新途中登出了：刷回来的新令牌不落库，调用方得到 signedOut")
    func signOutDuringRefreshStaysSignedOut() async throws {
        let store = InMemoryCredentialStore(credentials: Self.old)
        let refresher = GatedRefresher(outcome: .success(Self.fresh))
        let provider = AccessTokenProvider(credentials: store, refresher: refresher, server: { .production }, onRejected: {})

        let refreshing = Task { try await provider.refreshedToken(replacing: "old-at") }
        for _ in 0..<1_000 where await refresher.waiting == 0 { await Task.yield() }
        try store.clearCredentials()
        await refresher.release()

        await #expect(throws: AuthError.signedOut) { try await refreshing.value }
        #expect(store.stored == nil)
    }

    @Test("刷新途中登出又登录了另一份：旧的刷新结果不盖掉新凭据，被拒也不把新登录登出")
    func reSignInDuringRefreshKeepsNewLogin() async throws {
        let other = Credentials(accessToken: "other-at", refreshToken: "other-rt", accessTokenExpiresAt: .distantFuture, refreshTokenExpiresAt: .distantFuture, deviceID: 11)
        for outcome in [Result<TokenGrant, AuthError>.success(Self.fresh), .failure(.refreshRejected)] {
            let store = InMemoryCredentialStore(credentials: Self.old)
            let refresher = GatedRefresher(outcome: outcome)
            let rejections = RejectionCounter()
            let provider = AccessTokenProvider(credentials: store, refresher: refresher, server: { .production }, onRejected: { rejections.hit() })

            let refreshing = Task { try await provider.refreshedToken(replacing: "old-at") }
            for _ in 0..<1_000 where await refresher.waiting == 0 { await Task.yield() }
            try store.saveCredentials(other)
            await refresher.release()

            #expect(try await refreshing.value == "other-at")
            #expect(store.stored == other)
            #expect(rejections.value == 0)
        }
    }

    @Test("中继取令牌（连接与逐通道握手都用它）：已过期先刷新再交出；并发的调用方共用那一次刷新")
    func relayTokenRefreshesWhenExpired() async throws {
        let store = InMemoryCredentialStore(credentials: Self.old)
        let refresher = GatedRefresher(outcome: .success(Self.fresh))
        let provider = AccessTokenProvider(credentials: store, refresher: refresher, server: { .production }, onRejected: {})

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<3 { group.addTask { try await provider.unexpiredAccessToken() } }
            await refresher.settle()
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(tokens == Array(repeating: "new-at", count: 3))
        #expect(await refresher.calls == ["old-rt"])
        #expect(store.stored?.accessToken == "new-at")
    }

    @Test("中继取令牌：离到期还远就原样交出，不刷新")
    func relayTokenStillValid() async throws {
        var valid = Self.old
        valid.accessTokenExpiresAt = Date().addingTimeInterval(600)
        let refresher = GatedRefresher(outcome: .success(Self.fresh))
        let provider = AccessTokenProvider(credentials: InMemoryCredentialStore(credentials: valid), refresher: refresher, server: { .production }, onRejected: {})
        #expect(try await provider.unexpiredAccessToken() == "old-at")
        #expect(await refresher.calls.isEmpty)
    }

    @Test("中继取令牌时刷新被拒：登出，调用方得到 refreshRejected")
    func relayTokenRefreshRejected() async throws {
        let refresher = GatedRefresher(outcome: .failure(.refreshRejected))
        await refresher.release()
        let rejections = RejectionCounter()
        let provider = AccessTokenProvider(
            credentials: InMemoryCredentialStore(credentials: Self.old), refresher: refresher, server: { .production }, onRejected: { rejections.hit() }
        )
        await #expect(throws: AuthError.refreshRejected) { try await provider.unexpiredAccessToken() }
        #expect(rejections.value == 1)
    }

    @Test("没有凭据：取令牌即 signedOut")
    func signedOut() async {
        let provider = AccessTokenProvider(credentials: InMemoryCredentialStore(), refresher: GatedRefresher(outcome: .success(Self.fresh)), server: { .production }, onRejected: {})
        await #expect(throws: AuthError.signedOut) { try await provider.accessToken() }
    }

    @Test("带令牌的请求遇 401：刷新一次后以新令牌重试原请求；并发的 401 共用那一次刷新")
    func authorizedTransportRetriesOnce() async throws {
        let store = InMemoryCredentialStore(credentials: Self.old)
        let refresher = GatedRefresher(outcome: .success(Self.fresh))
        await refresher.release()
        let provider = AccessTokenProvider(credentials: store, refresher: refresher, server: { .production }, onRejected: {})
        let inner = FakeHTTPTransport { request in
            request.headers["Authorization"] == "Bearer new-at" ? HTTPResponse(status: 200, body: Data("ok".utf8)) : HTTPResponse(status: 401)
        }
        let transport = AuthorizedTransport(inner: inner, tokens: provider)
        let url = URL(string: "https://app.agentrehub.com/v1/devices")!

        let responses = try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            for _ in 0..<4 { group.addTask { try await transport.send(HTTPRequest(method: "GET", url: url)) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(responses.map(\.status) == [200, 200, 200, 200])
        #expect(await refresher.calls.count == 1)
        let sent = await inner.requests.map { $0.headers["Authorization"] }
        #expect(sent.filter { $0 == "Bearer new-at" }.count == 4)
    }

    @Test("重试后仍 401：不再第二次刷新，原样交回 401")
    func noSecondRefresh() async throws {
        let store = InMemoryCredentialStore(credentials: Self.old)
        let refresher = GatedRefresher(outcome: .success(Self.fresh))
        await refresher.release()
        let provider = AccessTokenProvider(credentials: store, refresher: refresher, server: { .production }, onRejected: {})
        let inner = FakeHTTPTransport { _ in HTTPResponse(status: 401) }
        let transport = AuthorizedTransport(inner: inner, tokens: provider)

        let response = try await transport.send(HTTPRequest(method: "GET", url: URL(string: "https://app.agentrehub.com/v1/devices")!))

        #expect(response.status == 401)
        #expect(await refresher.calls.count == 1)
        #expect(await inner.requests.count == 2)
    }
}
