import AgentreRelay
import Testing

/// 退让的形状：指数、封顶、半幅抖动（与控制台 relayBackoff、daemon HubLink 同形）。
struct RelayBackoffTests {
    let backoff = RelayBackoff(base: .seconds(1), cap: .seconds(30))

    @Test("抖动取中值时逐次翻倍，到封顶后不再增长")
    func exponentialAndCapped() {
        let delays = (0..<8).map { backoff.delay(afterFailures: $0, random: 0.5) }
        #expect(delays == [
            .milliseconds(750), .milliseconds(1500), .seconds(3), .seconds(6),
            .seconds(12), .milliseconds(22500), .milliseconds(22500), .milliseconds(22500),
        ])
    }

    @Test("抖动落在上限的一半到全额之间；越界的随机数被夹回")
    func jitterRange() {
        #expect(backoff.delay(afterFailures: 2, random: 0) == .seconds(2))
        #expect(backoff.delay(afterFailures: 2, random: 1) == .seconds(4))
        #expect(backoff.delay(afterFailures: 2, random: -3) == .seconds(2))
        #expect(backoff.delay(afterFailures: 2, random: 9) == .seconds(4))
        #expect(backoff.delay(afterFailures: 40, random: 1) == .seconds(30))
    }
}
