import AgentreDomain
import AgentreWire
import Foundation

/// 新建对话的派发：在选中那台机器的 `machine:` 通道上发 runtime.run（对照控制台 dispatch.ts）。
/// 会话号由手机铸好带过去；对端确认的必须是同一条，否则判为没开起来。
public struct RelayDispatcher: NewConversationDispatching {
    private let connection: RelayConnection
    private let source: RelaySourceDevice

    public init(connection: RelayConnection, source: RelaySourceDevice) {
        self.connection = connection
        self.source = source
    }

    public func dispatch(_ request: DispatchRequest) async throws {
        var run = Agentre_Wire_RuntimeRunRequest()
        run.conversationID = request.conversationID
        run.title = request.title
        run.userText = request.userText
        run.agentSyncID = request.agentSyncID
        run.projectSyncID = request.projectSyncID ?? ""
        run.cwd = request.target.cwd
        // agentID 是桌面端的本地主键，手机没有也不编；账号级归属由 agent_sync_id 表达。
        run.agentID = 0
        var backend = Agentre_Wire_AgentBackend()
        backend.type = request.target.backendType
        // agentred 持设备凭据按同步号取整份后端配置；桌面端不走这条通路，不带。
        if request.target.kind == "agentred", !request.target.backendSyncID.isEmpty {
            backend.syncID = request.target.backendSyncID
        }
        run.backend = backend
        run.sourceDevice = source.fingerprint
        run.sourceDeviceName = source.name

        let machine = request.target.deviceFingerprint
        do {
            if request.target.kind == "agentred", request.target.backendType == "piagent" {
                try await dispatchPi(run, on: machine)
            } else {
                try confirm(try await send(run, on: machine), run)
            }
        } catch let failure as RelayFailure {
            throw Self.dispatchFailure(failure)
        }
    }

    /// agentred 上的 Pi 用同一个 runtime.run 依次注册 generation、准备、启动，三次带同一个 generation
    /// 令牌（放在 permission_mode 上，daemon 据它认属主）。半途失败就撤掉这条会话，交回原来的失败。
    private func dispatchPi(_ base: Agentre_Wire_RuntimeRunRequest, on machine: String) async throws {
        var run = base
        run.permissionMode = "mobile-pi-generation-\(UUID().uuidString.lowercased())"
        do {
            try confirm(try await send(run, on: machine), run)
            let prepared = try await send(run, on: machine)
            try confirm(prepared, run)
            let providerSession = prepared.providerSessionID.trimmingCharacters(in: .whitespaces)
            guard !providerSession.isEmpty else { throw DispatchFailure.rejected }
            run.providerSessionID = providerSession
            let started = try await send(run, on: machine)
            try confirm(started, run)
            guard started.providerSessionID.trimmingCharacters(in: .whitespaces) == providerSession else { throw DispatchFailure.rejected }
        } catch {
            var abort = Agentre_Wire_RuntimeAbortRequest()
            abort.conversationID = run.conversationID
            // 清理失败不能盖掉原来那个失败。派发被取消（离开了新建对话屏）时照样要撤：清理放在
            // 不随调用方取消的任务里。
            let connection = connection
            let request = abort
            await Task {
                let _: Agentre_Wire_RuntimeAbortResponse? = try? await connection.call(machine: machine, .runtimeAbort, request)
            }.value
            throw error
        }
    }

    private func send(_ run: Agentre_Wire_RuntimeRunRequest, on machine: String) async throws -> Agentre_Wire_RuntimeRunResponse {
        try await connection.call(machine: machine, .runtimeRun, run)
    }

    private func confirm(_ ack: Agentre_Wire_RuntimeRunResponse, _ run: Agentre_Wire_RuntimeRunRequest) throws {
        guard ack.conversationID == run.conversationID else { throw DispatchFailure.rejected }
    }

    /// 没得到应答的（连不上、到期、通道被关）都是「连不上那台机器」；对端明确拒绝或答非所问是「没开起来」；
    /// 版本不等是要更新 App（规格「连接与协议」）。
    static func dispatchFailure(_ failure: RelayFailure) -> DispatchFailure {
        switch failure {
        case .updateRequired: .updateRequired
        case .timedOut, .connectionLost, .machineUnreachable: .unreachable
        case .refused, .unrecognisedResponse: .rejected
        }
    }
}
