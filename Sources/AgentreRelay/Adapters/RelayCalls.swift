import AgentreDomain
import AgentreWire
import Foundation
import SwiftProtobuf

/// 本机作为发起端的身份：runtime.run 的 source_device / source_device_name，
/// 机器据它把「来自 <设备>」标在这一轮上。
public struct RelaySourceDevice: Sendable, Equatable {
    public let fingerprint: String
    public let name: String

    public init(fingerprint: String, name: String) {
        self.fingerprint = fingerprint
        self.name = name
    }
}

/// 一条会话经哪台机器的通道走：默认就是会话键上的那台。装配层换成本地库记下的承载机；
/// 查不到承载机时抛出，而不是拿会话键上的发起端去顶（二者不可互相代替）。
public typealias RelayCarrier = @Sendable (ConversationKey) async throws -> String

extension RelayConnection {
    /// 在 `machine:<fingerprint>` 上发一次 RPC；中继的收场一律转成 `RelayFailure`。
    func call<Response: SwiftProtobuf.Message>(
        machine fingerprint: String,
        _ method: Agentre_Wire_RpcMethod,
        _ request: some SwiftProtobuf.Message,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let channel = await channel(for: .machine(fingerprint: fingerprint))
        return try await relayFailures { try await channel.call(method, request, as: Response.self) }
    }
}

/// 把中继层的错误换成领域失败；取消照原样往上走。
func relayFailures<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as RelayCallError {
        throw RelayFailure(error)
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as RelayFailure {
        throw error
    } catch {
        // 请求编不出来之类：对用户而言都是「没办成」。
        throw RelayFailure.unrecognisedResponse
    }
}
