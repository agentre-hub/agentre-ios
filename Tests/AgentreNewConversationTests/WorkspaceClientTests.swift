import AgentreDomain
import AgentreREST
import AgentreTestSupport
import Foundation
import Testing

/// `/v1/workspace/*` 三个只读端点（agentre-server/internal/api/workspace/workspace.go）。
@Suite("工作区 REST")
struct WorkspaceClientTests {
    let server = ServerAddress(string: "https://agentre.test")!

    @Test("Agent 清单：执行目标链逐档解开；没加入项目时那个键缺席即空")
    func decodesAgents() async throws {
        let transport = FakeHTTPTransport { _ in .cagoData(#"""
        {"agents":[
          {"sync_id":"ag-1","name":"coder","project_sync_ids":["p1"],"has_available_target":true,
           "exec_targets":[{"rank":1,"backend_sync_id":"b1","device_unspecified":false,"device_id":3,"device_name":"mini","backend_type":"codex","availability":"available","current":true},
                           {"rank":2,"device_unspecified":true,"availability":"no_device","current":false}]},
          {"sync_id":"ag-2","name":"reviewer","has_available_target":false,"exec_targets":[]}
        ]}
        """#) }
        let agents = try await WorkspaceClient(transport: transport, server: server).agents()
        #expect(agents == [
            WorkspaceAgent(syncID: "ag-1", name: "coder", projectSyncIDs: ["p1"], execTargets: [
                ExecTarget(rank: 1, backendSyncID: "b1", deviceName: "mini", backendType: "codex", availability: .available, current: true),
                ExecTarget(rank: 2, deviceUnspecified: true, availability: .noDevice),
            ], hasAvailableTarget: true),
            WorkspaceAgent(syncID: "ag-2", name: "reviewer", hasAvailableTarget: false),
        ])
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://agentre.test/v1/workspace/agents")
    }

    @Test("项目树：父节点缺席即根")
    func decodesProjects() async throws {
        let transport = FakeHTTPTransport { _ in .cagoData(#"""
        {"projects":[{"sync_id":"root","name":"server","sort_order":1,"configured":true},
                     {"sync_id":"fe","name":"frontend","parent_sync_id":"root","sort_order":0,"configured":false,"members":[{"sync_id":"m","agent_sync_id":"ag"}]}]}
        """#) }
        let projects = try await WorkspaceClient(transport: transport, server: server).projects()
        #expect(projects == [
            WorkspaceProject(syncID: "root", name: "server", sortOrder: 1),
            WorkspaceProject(syncID: "fe", name: "frontend", parentSyncID: "root"),
        ])
        #expect(await transport.requests.first?.url.absoluteString == "https://agentre.test/v1/workspace/projects")
    }

    @Test("派发计划：只带给了的参数；逐档原因与选中那一档都解开")
    func dispatchPlan() async throws {
        let transport = FakeHTTPTransport { _ in .cagoData(#"""
        {"agent_sync_id":"ag-1","tiers":[
          {"rank":1,"backend_sync_id":"b1","device_id":3,"device_name":"mini","backend_type":"codex","kind":"agentred","availability":"project_path_missing","current":false},
          {"rank":2,"backend_sync_id":"b2","device_id":4,"device_name":"box","backend_type":"claudecode","kind":"agentred","availability":"available","current":true}],
         "chosen":{"device_fingerprint":"fp-box","device_id":4,"device_name":"box","backend_sync_id":"b2","backend_type":"claudecode","kind":"agentred","cwd":"/srv/app"},
         "projects":[]}
        """#) }
        let client = WorkspaceClient(transport: transport, server: server)
        let plan = try await client.dispatchPlan(DispatchPlanQuery(agentSyncID: "ag-1", projectSyncID: "p 1", targetBackendSyncID: "b2"))
        #expect(plan == DispatchPlan(agentSyncID: "ag-1", tiers: [
            DispatchTier(rank: 1, backendSyncID: "b1", deviceName: "mini", backendType: "codex", kind: "agentred", availability: .projectPathMissing),
            DispatchTier(rank: 2, backendSyncID: "b2", deviceName: "box", backendType: "claudecode", kind: "agentred", availability: .available),
        ], chosen: DispatchChoice(deviceFingerprint: "fp-box", deviceName: "box", backendSyncID: "b2", backendType: "claudecode", kind: "agentred", cwd: "/srv/app")))

        _ = try await client.dispatchPlan(DispatchPlanQuery(agentSyncID: "ag-1"))
        let urls = await transport.requests.map(\.url)
        let first = try #require(URLComponents(url: urls[0], resolvingAgainstBaseURL: false))
        #expect(first.path == "/v1/workspace/dispatch-target")
        #expect(Set(first.queryItems ?? []) == [
            URLQueryItem(name: "agent_sync_id", value: "ag-1"),
            URLQueryItem(name: "project_sync_id", value: "p 1"),
            URLQueryItem(name: "target_backend_sync_id", value: "b2"),
        ])
        let second = try #require(URLComponents(url: urls[1], resolvingAgainstBaseURL: false))
        #expect(second.queryItems == [URLQueryItem(name: "agent_sync_id", value: "ag-1")])
    }

    @Test("全部档都不可用时 chosen 为 null，解作没有选中")
    func nullChoice() async throws {
        let transport = FakeHTTPTransport { _ in .cagoData(#"{"agent_sync_id":"ag","tiers":[{"rank":1,"availability":"unpaired","current":false}],"chosen":null,"projects":[]}"#) }
        let plan = try await WorkspaceClient(transport: transport, server: server).dispatchPlan(DispatchPlanQuery(agentSyncID: "ag"))
        #expect(plan.chosen == nil)
        #expect(plan.tiers == [DispatchTier(rank: 1, availability: .unpaired)])
    }

    @Test("失败与其它 REST 端点落到同一组事实：5xx 服务器出错、401 登录失效、认不出的正文")
    func failuresAreFacts() async throws {
        func fact(_ response: HTTPResponse) async -> FailureFact? {
            do {
                _ = try await WorkspaceClient(transport: FakeHTTPTransport { _ in response }, server: server).agents()
                return nil
            } catch {
                return FailureFact(presenting: error)
            }
        }
        #expect(await fact(HTTPResponse(status: 502)) == .serverUnavailable)
        #expect(await fact(HTTPResponse(status: 401)) == .signedOut)
        #expect(await fact(HTTPResponse(status: 200, body: Data("<html>".utf8))) == .unrecognisedResponse)
    }

    @Test("非 2xx 与认不出的正文都如实报错")
    func failures() async throws {
        let failing = WorkspaceClient(transport: FakeHTTPTransport { _ in HTTPResponse(status: 502) }, server: server)
        await #expect(throws: AuthError.unexpectedResponse(status: 502)) { try await failing.agents() }
        let garbled = WorkspaceClient(transport: FakeHTTPTransport { _ in HTTPResponse(status: 200, body: Data("<html>".utf8)) }, server: server)
        await #expect(throws: AuthError.unexpectedResponse(status: 200)) { try await garbled.projects() }
    }
}
