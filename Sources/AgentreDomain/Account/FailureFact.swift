import Foundation

/// 一次对用户可见的失败，解析成的事实。
///
/// 这是错误呈现层的全部词汇：没有一个成员带字符串或数字——错误码与对端原串在解析这一步
/// 就被丢掉，表现层手里只剩「发生了什么」，只能以自己的语言把它说出来（规格「失败与恢复」）。
public enum FailureFact: Sendable, Equatable, Hashable {
    /// 本机没有网络。
    case offline
    /// 有网络，但连不上服务器（找不到主机、拒绝连接、TLS 失败）。
    case serverUnreachable
    /// 服务器没有在期限内回应。
    case timedOut
    /// 登录已失效（刷新被拒、令牌不再被认）。
    case signedOut
    /// 服务器拒绝了这次操作。
    case notPermitted
    /// 撤销另一台设备被拒：以设备令牌只能撤销本机。
    case revokeNeedsConsole
    /// 服务器出错（5xx）。
    case serverUnavailable
    /// 服务器回了一个客户端认不出的应答。
    case unrecognisedResponse
    /// 协议版本不等：要更新 App。
    case updateRequired
    /// 没有可用的机器，及其原因。
    case noMachineAvailable(MachineUnavailableReason)
    /// 认不出的错误：只说没办成，不复述它。
    case unknown

    /// 把一个错误解析成事实。取消不是失败，返回 nil，不呈现。
    public init?(presenting error: any Error) {
        switch error {
        case is CancellationError:
            return nil
        case let error as AuthError:
            self = Self.fact(for: error)
        case let error as AccountError:
            switch error {
            case .revokeRefused: self = .revokeNeedsConsole
            }
        case let error as URLError:
            guard let fact = Self.fact(for: error) else { return nil }
            self = fact
        default:
            self = .unknown
        }
    }

    private static func fact(for error: AuthError) -> FailureFact {
        switch error {
        case .refreshRejected, .signedOut:
            return .signedOut
        case .unexpectedResponse(let status):
            switch status {
            case 401: return .signedOut
            case 403: return .notPermitted
            case 500...599: return .serverUnavailable
            default: return .unrecognisedResponse
            }
        }
    }

    private static func fact(for error: URLError) -> FailureFact? {
        switch error.code {
        case .cancelled:
            return nil
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timedOut
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return .serverUnreachable
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData:
            return .unrecognisedResponse
        default:
            return .unknown
        }
    }

    /// 据事实给出的下一步出口。
    public var exit: FailureExit {
        switch self {
        case .offline, .serverUnreachable, .timedOut, .serverUnavailable, .unrecognisedResponse, .unknown:
            .retry
        case .signedOut, .notPermitted, .revokeNeedsConsole, .updateRequired, .noMachineAvailable:
            .none
        }
    }
}

extension FailureFact: CaseIterable {
    public static var allCases: [FailureFact] {
        [
            .offline, .serverUnreachable, .timedOut, .signedOut, .notPermitted, .revokeNeedsConsole,
            .serverUnavailable, .unrecognisedResponse, .updateRequired, .unknown,
        ] + MachineUnavailableReason.allCases.map(FailureFact.noMachineAvailable)
    }
}

/// 端口的实现（中继、REST 适配器）已经把自己的失败解析成了事实：领域层不认识它的具体类型，
/// 经这一层照用那个事实（例如机器详情据它说出「要更新 App」而不是「没连上」）。
public protocol FactualFailure: Error {
    var fact: FailureFact { get }
}

/// 失败之后给用户的出口。登录已失效时根视图自己回到登录屏，不需要这里给。
public enum FailureExit: Sendable, Equatable {
    case retry
    case none
}

/// 「没有可用的机器」的原因，取自服务端派发计划里逐档的 availability
/// （agentre-server/internal/api/workspace/workspace.go 的 DispatchTierItem：
/// available | offline | unpaired | no_device | project_path_missing）。
///
/// 成员按「用户最能就此行动」排序：有机器在线只是缺项目路径 > 机器不在线 > 没配对 > 没指定机器。
public enum MachineUnavailableReason: Sendable, Equatable, Hashable, CaseIterable {
    case projectPathMissing
    case offline
    case unpaired
    case noDevice
    /// 服务端给了本客户端认不出的取值：只说没有可用的机器，不复述那个取值。
    case unspecified
}
