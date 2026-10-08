import Foundation
import Network
import Observation

/// 这台设备此刻有没有网络，取自系统的网络路径。界面据它把可发的动作置为不可用并如实说明是离线。
@MainActor
@Observable
final class Connectivity {
    private(set) var isOffline = false
    @ObservationIgnored private var watcher: Task<Void, Never>?

    /// - Parameter updates: 网络路径的每一次变化（true = 有网）。
    init(updates: AsyncStream<Bool>) {
        watcher = Task { [weak self] in
            for await online in updates {
                self?.isOffline = !online
            }
        }
    }

    isolated deinit {
        watcher?.cancel()
    }

    /// 系统网络路径（NWPathMonitor）：路径可用即有网。
    nonisolated static func systemPath() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.agentrehub.agentre.network-path"))
        }
    }
}
