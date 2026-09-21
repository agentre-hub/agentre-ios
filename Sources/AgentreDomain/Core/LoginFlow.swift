import Foundation
import Observation

/// 登录屏背后的设备流状态机。
@MainActor @Observable
public final class LoginFlow {
    public enum State: Sendable, Equatable {
        case idle
        case awaitingApproval
        case expired
        case denied
        case failed
        case signedIn
    }

    public private(set) var state: State = .idle
    public private(set) var serverAddress: ServerAddress

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let deviceAuth: DeviceAuthorizing
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let servers: ServerAddressStore
    @ObservationIgnored private let opener: VerificationOpening
    @ObservationIgnored private let sleeper: Sleeping
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        session: AppSession,
        deviceAuth: DeviceAuthorizing,
        credentials: CredentialStore,
        servers: ServerAddressStore,
        opener: VerificationOpening,
        sleeper: Sleeping,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.deviceAuth = deviceAuth
        self.credentials = credentials
        self.servers = servers
        self.opener = opener
        self.sleeper = sleeper
        self.now = now
        self.serverAddress = servers.load()
    }

    /// RFC 8628 §3.5：收到 slow_down 时轮询间隔加 5 秒。
    static let slowDownIncrement: Duration = .seconds(5)
    /// RFC 8628 §3.2：服务端没给间隔时默认 5 秒。
    static let defaultInterval: Duration = .seconds(5)

    /// 发起设备流，直接打开带确认码的验证地址，再轮询到一个收场为止。
    public func signIn() async {
        guard state != .awaitingApproval else { return }
        state = .awaitingApproval
        state = await runDeviceFlow()
    }

    /// 改服务器地址。只接受合法的 http / https 地址；不合法时原地址不变。
    public func setServerAddress(_ text: String) -> Bool {
        guard let address = ServerAddress(string: text) else { return false }
        servers.save(address)
        serverAddress = address
        return true
    }

    private func runDeviceFlow() async -> State {
        let server = serverAddress
        let authorization: DeviceAuthorization
        do {
            let fingerprint = try credentials.deviceFingerprint()
            authorization = try await deviceAuth.authorize(fingerprint: fingerprint, server: server)
        } catch {
            return .failed
        }
        opener.open(authorization.verificationURIComplete)

        let deadline = now().addingTimeInterval(authorization.expiresIn.seconds)
        var interval = authorization.interval > .zero ? authorization.interval : Self.defaultInterval
        while true {
            // 等完这一轮就过期了：不再多等一轮去问一个注定过期的码。
            guard now().addingTimeInterval(interval.seconds) <= deadline else { return .expired }
            do {
                try await sleeper.sleep(for: interval)
                switch try await deviceAuth.pollToken(deviceCode: authorization.deviceCode, server: server) {
                case .pending:
                    continue
                case .slowDown:
                    interval += Self.slowDownIncrement
                case .expired:
                    return .expired
                case .denied:
                    return .denied
                case let .authorized(grant, deviceID):
                    try session.signIn(with: Credentials(grant: grant, deviceID: deviceID, issuedAt: now()))
                    return .signedIn
                }
            } catch {
                return .failed
            }
        }
    }
}
