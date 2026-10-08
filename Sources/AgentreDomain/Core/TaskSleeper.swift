import Foundation

/// 真实的等待：`Task.sleep`，随任务取消而抛出。
public struct TaskSleeper: Sleeping {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
