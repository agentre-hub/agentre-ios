import AgentreDomain
import AgentreRelay
import AgentreREST
import AgentreStore
import Foundation

/// 账号名下的机器（REST 名册），按指纹查种类与名字。问不到时下次再问。
actor MachineDirectory {
    private let roster: any MachineRoster
    private var machines: [Machine]?

    init(roster: any MachineRoster) {
        self.roster = roster
    }

    func all() async throws -> [Machine] {
        if let machines { return machines }
        let fetched = try await roster.machines()
        machines = fetched
        return fetched
    }

    func kind(of fingerprint: String) async -> String? {
        if let known = machines?.first(where: { $0.fingerprint == fingerprint }) { return known.kind }
        machines = nil
        return try? await all().first { $0.fingerprint == fingerprint }?.kind
    }
}

/// 提及的候选：工作区 Agent（`/v1/workspace/agents`）与账号的机器（`/v1/devices`），
/// 与控制台 SessionComposer 同一份来路。Agent 的数字标识取它在清单里的位置
/// （控制台 SessionComposerBand.tsx:148-152 同此：本站的 Agent 身份是字符串同步号）。
struct RESTMentionSource: ComposerMentionSource {
    let workspace: any WorkspaceService
    let machines: MachineDirectory

    func mentionSources() async throws -> ComposerMentionSources {
        async let agents = workspace.agents()
        async let devices = machines.all()
        return try await ComposerMentionSources(
            agents: agents.enumerated().map { ComposerMentionAgent(id: Int64($0.offset + 1), name: $0.element.name) },
            devices: devices.map { ComposerMentionDevice(fingerprint: $0.fingerprint, name: $0.name, online: $0.online) }
        )
    }
}

/// 引擎目录里可选的模型：`GET /v1/engine/snapshot`（agentre-server/internal/api/engine/engine.go:192-199，
/// 挂在 router.go:363-370 的设备令牌组——`/v1/engine/providers` 只认浏览器会话，设备令牌进不去）。
/// 应答里带着供应商的 API key：这里只解模型键，别的字段一概不解、不留。
struct EngineCatalogClient: Sendable {
    let transport: any HTTPTransport
    let server: ServerAddress

    func models() async throws -> [ComposerModelChoice] {
        let response = try await transport.send(HTTPRequest(method: "GET", url: server.endpoint("/v1/engine/snapshot")))
        guard (200..<300).contains(response.status) else { throw AuthError.unexpectedResponse(status: response.status) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = try? decoder.decode(Envelope.self, from: response.body).data else {
            throw AuthError.unexpectedResponse(status: response.status)
        }
        return snapshot.providers.flatMap { provider in
            provider.models.filter(\.enabled).map { ComposerModelChoice(providerKey: provider.providerKey, modelKey: $0.modelKey) }
        }
    }

    private struct Envelope: Decodable {
        let data: Snapshot
    }

    private struct Snapshot: Decodable {
        let providers: [Provider]
    }

    private struct Provider: Decodable {
        let providerKey: String
        let models: [Model]
    }

    private struct Model: Decodable {
        let modelKey: String
        let enabled: Bool
    }
}

/// 输入区面板三项：权限档位问承载机的 runtimeCapabilities，模型目录取服务端引擎目录，
/// 会话此刻用的模型与思考档位取自本地库那一行（机器清单的 model_key / reasoning_effort）。
/// 后端配置的档位在引擎目录里只对后端所在的那台机器下发，手机拿不到。
struct ComposerSettingsAdapter: ComposerSettingsSource {
    let catalog: EngineCatalogClient
    let connection: RelayConnection
    let carrier: RelayCarrier

    func settings(for conversation: SavedConversation) async throws -> ComposerSettings {
        let machine = await carrier(conversation.key)
        async let models = try? catalog.models()
        async let modes = try? connection.permissionModes(backendType: conversation.backendType, on: machine)
        let (choices, permission) = await (models, modes)
        return ComposerSettings(
            conversation: conversation,
            permissionMode: permission?.defaultMode ?? "",
            permissionModes: permission?.allowed ?? [],
            models: choices ?? []
        )
    }
}
