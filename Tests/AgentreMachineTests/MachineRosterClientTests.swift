import AgentreDomain
import AgentreREST
import AgentreTestSupport
import Foundation
import Testing

@Suite("机器名册（REST）")
struct MachineRosterClientTests {
    let server = ServerAddress(string: "https://agentre.example")!

    @Test("GET /v1/devices：只留承载会话的机器，备注名优先，在线态与最后在线时刻原样带出")
    func rosterFromDevices() async throws {
        let transport = FakeHTTPTransport { _ in
            .cagoData(#"""
            {"devices":[
              {"id":1,"name":"studio.local","display_name":"Studio","kind":"desktop","platform":"darwin","version":"0.3.0","fingerprint":"fp-1","last_seen_at":1900000000000,"status":1,"online":true,"is_this_device":false},
              {"id":2,"name":"build-box","display_name":"","kind":"agentred","platform":"linux","version":"0.3.0","fingerprint":"fp-2","last_seen_at":1800000000000,"status":1,"online":false,"is_this_device":false},
              {"id":3,"name":"iPhone","display_name":"","kind":"mobile","platform":"ios","version":"0.1.0","fingerprint":"fp-3","last_seen_at":0,"status":1,"online":false,"is_this_device":true},
              {"id":4,"name":"Chrome","display_name":"","kind":"web","platform":"web","version":"","fingerprint":"fp-4","last_seen_at":0,"status":1,"online":false,"is_this_device":false}
            ]}
            """#)
        }
        let machines = try await MachineRosterClient(transport: transport, server: server).machines()
        #expect(machines == [
            Machine(id: 1, fingerprint: "fp-1", name: "Studio", kind: "desktop", platform: "darwin", version: "0.3.0", online: true, lastSeenAt: 1_900_000_000_000),
            Machine(id: 2, fingerprint: "fp-2", name: "build-box", kind: "agentred", platform: "linux", version: "0.3.0", online: false, lastSeenAt: 1_800_000_000_000),
        ])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://agentre.example/v1/devices")
    }

    @Test("非 2xx 与认不出的正文都抛错，不当成空名册")
    func failuresThrow() async throws {
        for response in [HTTPResponse(status: 500), HTTPResponse(status: 200, body: Data("nope".utf8))] {
            let transport = FakeHTTPTransport { _ in response }
            await #expect(throws: (any Error).self) {
                try await MachineRosterClient(transport: transport, server: server).machines()
            }
        }
    }
}
