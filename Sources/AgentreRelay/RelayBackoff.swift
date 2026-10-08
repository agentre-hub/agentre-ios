/// 重试的退让：指数、封顶、半幅抖动（与控制台 relayBackoff、daemon HubLink 同形）。
///
/// 抖动是必需的：同一次服务端故障被所有设备同时看见，没有抖动它们会整齐地同时重拨。
public struct RelayBackoff: Sendable {
    public let base: Duration
    public let cap: Duration

    public init(base: Duration, cap: Duration) {
        self.base = base
        self.cap = cap
    }

    public static let standard = RelayBackoff(base: .seconds(1), cap: .seconds(30))

    /// 连着失败了 `failures` 次（从 0 起）之后这一次等多久；`random` 取 [0,1]，越界被夹回。
    public func delay(afterFailures failures: Int, random: Double) -> Duration {
        var ceiling = base
        for _ in 0..<max(failures, 0) where ceiling < cap { ceiling *= 2 }
        ceiling = min(ceiling, cap)
        let jitter = min(max(random, 0), 1)
        let ceilingMs = Double(ceiling.components.seconds) * 1000
            + Double(ceiling.components.attoseconds) / 1e15
        return .milliseconds(Int64((ceilingMs * (0.5 + jitter / 2)).rounded()))
    }
}
