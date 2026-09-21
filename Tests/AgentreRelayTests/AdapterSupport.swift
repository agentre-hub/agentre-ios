import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

// 适配器测试的共用接缝：真实的 RelayConnection / RelayChannel 跑在任务 3 的伪套接字上，
// 测试站在中继服务端那一侧，看适配器写出的请求、给回应答或错误。

extension Harness {
    /// 等适配器在 `machine:<fingerprint>` 上开出通道并完成握手，交回套接字与通道 ID。
    /// 能等到这条声明本身就证明了寻址：通道的第一帧就是 `machine:<fingerprint>`。
    func machineChannel(
        _ fingerprint: String, socketIndex: Int = 0, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (FakeSocket, String) {
        let socket = try await dialer.socket(socketIndex, sourceLocation: sourceLocation)
        let id = try await socket.channelID(for: .machine(fingerprint: fingerprint), sourceLocation: sourceLocation)
        try await socket.acceptHandshake(on: id, sourceLocation: sourceLocation)
        return (socket, id)
    }

    /// 已启动连接的一套。
    static func started() async -> Harness {
        let harness = Harness()
        await harness.connection.start()
        return harness
    }
}

extension Agentre_Wire_RpcFrame {
    /// 解出这一帧请求的载荷。
    func body<M: SwiftProtobuf.Message>(_ type: M.Type) throws -> M {
        try M(serializedBytes: request.encodedPayload)
    }
}

/// 适配器调用的两种失败收场：对端以错误码拒绝（带一段对端原串），与到期无人应答。
enum FailureScenario: CaseIterable {
    case peerError
    case timeout

    func apply(_ harness: Harness, _ socket: FakeSocket, _ id: String, _ request: Agentre_Wire_RpcFrame) async throws {
        switch self {
        case .peerError:
            socket.fail(id, to: request, code: -32_000, message: "sqlite: no such row conv-1 (peer raw string)")
        case .timeout:
            // 等这次调用的兜底计时挂上，再把时间推过它。
            let deadline = try await eventually("call deadline") {
                harness.clock.pendingSleeps.contains(RelayChannel.defaultDeadline) ? RelayChannel.defaultDeadline : nil
            }
            harness.clock.advance(by: deadline)
        }
    }

    /// 对应的领域失败：没有错误码、没有对端原串。
    var expected: RelayFailure {
        switch self {
        case .peerError: .refused
        case .timeout: .timedOut
        }
    }
}

/// 在 `machine:<fingerprint>` 上等 `method` 的请求，按 `scenario` 让它失败，交回调用抛出的错误。
func failure<T: Sendable>(
    _ scenario: FailureScenario,
    method: Agentre_Wire_RpcMethod,
    on fingerprint: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ call: @escaping @Sendable (Harness) async throws -> T
) async throws -> (any Error)? {
    let harness = await Harness.started()
    let task = Task { try await call(harness) }
    let (socket, id) = try await harness.machineChannel(fingerprint, sourceLocation: sourceLocation)
    let request = try await socket.nextRequest(on: id, method: method, sourceLocation: sourceLocation)
    try await scenario.apply(harness, socket, id, request)
    do {
        _ = try await task.value
        return nil
    } catch {
        return error
    }
}
