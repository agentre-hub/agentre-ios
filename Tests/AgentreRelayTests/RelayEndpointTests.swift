import AgentreDomain
import AgentreRelay
import Foundation
import Testing

struct RelayEndpointTests {
    @Test("https 服务器 → wss://…/v1/relay/client；http（开发服）→ ws")
    func clientURL() throws {
        #expect(RelayEndpoint.clientURL(for: .production).absoluteString == "wss://app.agentrehub.com/v1/relay/client")
        let dev = try #require(ServerAddress(string: "http://docker.local:8443/"))
        #expect(RelayEndpoint.clientURL(for: dev).absoluteString == "ws://docker.local:8443/v1/relay/client")
    }

    @Test("真实拨号：access token 直接进 Authorization 头，读上限 = 信封读上限；不走子协议票据")
    func urlSessionTask() {
        let task = URLSessionRelayDialer().makeTask(url: URL(string: "wss://relay.test/v1/relay/client")!, accessToken: "tok")
        #expect(task.originalRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(task.originalRequest?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == nil)
        #expect(task.maximumMessageSize == RelayEnvelope.readLimit)
        task.cancel()
    }
}
