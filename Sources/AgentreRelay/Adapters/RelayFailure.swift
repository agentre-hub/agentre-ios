import AgentreDomain

/// 一次中继适配器调用没办成：只剩事实，错误码与对端原串在这里就丢掉了（规格「失败与恢复」）。
/// 界面经 `fact` 以自己的语言重述。
public enum RelayFailure: FactualFailure, Sendable, Equatable {
    /// 兜底期限到了还没有应答。
    case timedOut
    /// 与服务器的中继连接断了，已发出的请求结果未知。
    case connectionLost
    /// 通往那台机器的通道被关掉了（机器不在线，或服务端判死了这一条）。
    case machineUnreachable
    /// 那台机器的协议版本与本 App 不等。
    case updateRequired
    /// 机器拒绝了这次请求。
    case refused
    /// 机器的应答对不上这次请求，或解不开。
    case unrecognisedResponse

    public init(_ error: RelayCallError) {
        switch error {
        case .timedOut: self = .timedOut
        case .disconnected: self = .connectionLost
        case .channelClosed: self = .machineUnreachable
        case .updateRequired: self = .updateRequired
        case .unexpectedResponse: self = .unrecognisedResponse
        case .rejected: self = .refused
        }
    }

    /// 呈现层的事实。对端的拒绝原因不复述，只说没办成。
    public var fact: FailureFact {
        switch self {
        case .timedOut: .timedOut
        case .connectionLost: .serverUnreachable
        case .machineUnreachable: .noMachineAvailable(.offline)
        case .updateRequired: .updateRequired
        case .refused: .unknown
        case .unrecognisedResponse: .unrecognisedResponse
        }
    }
}
