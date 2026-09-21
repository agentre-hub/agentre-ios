import AgentreDomain
import AgentreWire
import Foundation
import SwiftProtobuf

// 应用目标只装配、链接不到 AgentreWire 的符号：它要从帧里读的、要经通道问的那几样 wire 形状，
// 由认得 wire 的这一层给出。通道由调用方经 `WireCalling` 递进来（本模块不认识中继）。

/// 能在一条通道上发一次 wire RPC 的东西（中继通道即是）。
public protocol WireCalling: Sendable {
    func call<Response: SwiftProtobuf.Message>(
        _ method: Agentre_Wire_RpcMethod, _ request: some SwiftProtobuf.Message, as type: Response.Type, deadline: Duration
    ) async throws -> Response
}

/// 执行端报的权限档位（RuntimeCapabilitiesResponse.permission_mode）。
public struct PermissionModes: Sendable, Equatable {
    /// 空 = 这个后端没有权限门。
    public var allowed: [String]
    public var defaultMode: String

    public init(allowed: [String], defaultMode: String) {
        self.allowed = allowed
        self.defaultMode = defaultMode
    }

    /// 问 `caller` 那一头的执行端。对端没报这一格（太老 / 答不出来）时抛错：那是「没答」，
    /// 不是「没有权限门」。
    public static func query(backendType: String, via caller: some WireCalling, deadline: Duration = .seconds(30)) async throws -> PermissionModes {
        var request = Agentre_Wire_RuntimeCapabilitiesRequest()
        request.backendType = backendType
        let response = try await caller.call(.runtimeCapabilities, request, as: Agentre_Wire_RuntimeCapabilitiesResponse.self, deadline: deadline)
        guard response.hasPermissionMode else { throw WireQueryError.notAnswered }
        return PermissionModes(allowed: response.permissionMode.allowedModes, defaultMode: response.permissionMode.defaultMode)
    }
}

public enum WireQueryError: Error, Equatable {
    case notAnswered
}

/// 一帧对输入区的回合说了什么（宿主从转录事件里递给输入区的三件事）。
public enum TurnSignal: Sendable, Equatable {
    case started
    /// 正常收场 = 没有停止文案；出错与用户中断都不是正常收场。
    case ended(normally: Bool)
    case steersConsumed([ComposerConsumedSteer])

    /// `payload` 是一帧 `RpcNotification` 的字节；与回合无关的帧为 nil。
    public init?(payload: Data) {
        guard let notification = try? Agentre_Wire_RpcNotification(serializedBytes: payload) else { return nil }
        switch notification.payload {
        case .turnStarted, .autonomousTurnStarted:
            self = .started
        case .runResultDone(let done), .autonomousTurnDone(let done):
            self = .ended(normally: done.stopErrorMessage.isEmpty)
        case .runtimeEvent(let event), .autonomousTurnEvent(let event):
            guard case .steerConsumed(let consumed) = event.event else { return nil }
            self = .steersConsumed(consumed.steers.map { ComposerConsumedSteer(queuedID: $0.queuedID, text: $0.text) })
        default:
            return nil
        }
    }
}
