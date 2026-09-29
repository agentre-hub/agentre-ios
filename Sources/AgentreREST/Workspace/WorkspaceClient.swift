import AgentreDomain
import Foundation

/// agentre-server `/v1/workspace/*` 的只读端点（internal/api/workspace/workspace.go）。
public struct WorkspaceClient: WorkspaceService {
    private let transport: HTTPTransport
    private let server: ServerAddress

    /// - Parameter transport: 带设备访问令牌的传输（`AuthorizedTransport`）。
    public init(transport: HTTPTransport, server: ServerAddress) {
        self.transport = transport
        self.server = server
    }

    public func agents() async throws -> [WorkspaceAgent] {
        try await get(AgentsBody.self, server.endpoint("/v1/workspace/agents")).agents.map(\.domain)
    }

    public func projects() async throws -> [WorkspaceProject] {
        try await get(ProjectsBody.self, server.endpoint("/v1/workspace/projects")).projects.map(\.domain)
    }

    public func dispatchPlan(_ query: DispatchPlanQuery) async throws -> DispatchPlan {
        var components = URLComponents(url: server.endpoint("/v1/workspace/dispatch-target"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "agent_sync_id", value: query.agentSyncID)]
        if let project = query.projectSyncID, !project.isEmpty { items.append(URLQueryItem(name: "project_sync_id", value: project)) }
        if let target = query.targetBackendSyncID, !target.isEmpty { items.append(URLQueryItem(name: "target_backend_sync_id", value: target)) }
        components?.queryItems = items
        guard let url = components?.url else { throw AuthError.unexpectedResponse(status: 0) }
        return try await get(PlanBody.self, url).domain
    }

    private func get<T: Decodable>(_ type: T.Type, _ url: URL) async throws -> T {
        let response = try await transport.send(HTTPRequest(method: "GET", url: url))
        guard response.isSuccess else { throw AuthError.unexpectedResponse(status: response.status) }
        return try CagoEnvelope.decodeData(T.self, from: response)
    }
}

// 与服务端 JSON 一一对应；蛇形命名由 CagoEnvelope 的解码器统一转换。

private struct AgentsBody: Decodable {
    let agents: [Agent]

    struct Agent: Decodable {
        let syncId: String
        let name: String
        let projectSyncIds: [String]?
        let execTargets: [Target]?
        let hasAvailableTarget: Bool
        let avatarColor: String?

        var domain: WorkspaceAgent {
            WorkspaceAgent(
                syncID: syncId, name: name, projectSyncIDs: projectSyncIds ?? [],
                execTargets: (execTargets ?? []).map(\.domain), hasAvailableTarget: hasAvailableTarget,
                avatarColor: IdentityColor(wireToken: avatarColor)
            )
        }
    }

    struct Target: Decodable {
        let rank: Int
        let backendSyncId: String?
        let deviceUnspecified: Bool?
        let deviceName: String?
        let backendType: String?
        let availability: String
        let current: Bool?

        var domain: ExecTarget {
            ExecTarget(
                rank: rank, backendSyncID: backendSyncId ?? "", deviceUnspecified: deviceUnspecified ?? false,
                deviceName: deviceName ?? "", backendType: backendType ?? "",
                availability: TargetAvailability(wire: availability), current: current ?? false
            )
        }
    }
}

private struct ProjectsBody: Decodable {
    let projects: [Project]

    struct Project: Decodable {
        let syncId: String
        let name: String
        let parentSyncId: String?
        let sortOrder: Int?
        let color: String?

        var domain: WorkspaceProject {
            WorkspaceProject(
                syncID: syncId, name: name, parentSyncID: parentSyncId.flatMap { $0.isEmpty ? nil : $0 }, sortOrder: sortOrder ?? 0,
                color: IdentityColor(wireToken: color)
            )
        }
    }
}

private struct PlanBody: Decodable {
    let agentSyncId: String
    let tiers: [Tier]?
    let chosen: Choice?

    var domain: DispatchPlan {
        DispatchPlan(agentSyncID: agentSyncId, tiers: (tiers ?? []).map(\.domain), chosen: chosen?.domain)
    }

    struct Tier: Decodable {
        let rank: Int
        let backendSyncId: String?
        let deviceName: String?
        let backendType: String?
        let kind: String?
        let availability: String

        var domain: DispatchTier {
            DispatchTier(
                rank: rank, backendSyncID: backendSyncId ?? "", deviceName: deviceName ?? "", backendType: backendType ?? "",
                kind: kind ?? "", availability: TargetAvailability(wire: availability)
            )
        }
    }

    struct Choice: Decodable {
        let deviceFingerprint: String
        let deviceName: String
        let backendSyncId: String?
        let backendType: String
        let kind: String?
        let cwd: String?

        var domain: DispatchChoice {
            DispatchChoice(
                deviceFingerprint: deviceFingerprint, deviceName: deviceName, backendSyncID: backendSyncId ?? "",
                backendType: backendType, kind: kind ?? "", cwd: cwd ?? ""
            )
        }
    }
}
