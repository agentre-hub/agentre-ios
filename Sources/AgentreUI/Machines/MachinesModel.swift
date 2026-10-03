import AgentreDomain
import Foundation
import Observation

/// 机器标签：账号名下的机器与各自的在线态，取自 REST 名册。
@MainActor
@Observable
public final class MachinesModel {
    public private(set) var machines: [Machine] = []
    /// 名册没取到（且手上没有旧的可显示）。
    public private(set) var loadFailed = false
    /// 名册没取到时的事实（屏上以用户语言重述）；取到了、或手上有旧的可显示时为 nil。
    public private(set) var failure: FailureFact?
    /// 在线机器现算的会话计数（`sessionCounts`），按指纹存放；离线或还没问到的机器没有这一项——不是零
    /// （规格「08」）。
    public private(set) var counts: [String: MachineSessionCounts] = [:]

    /// 名册取到了而没有一台在线：没有可用的机器，及其原因（一台都没有即还没配对）。
    public var unavailable: MachineUnavailableReason? {
        guard hasLoaded, !machines.contains(where: \.online) else { return nil }
        return machines.isEmpty ? .unpaired : .offline
    }

    private let roster: any MachineRoster
    private let sessions: any MachineSessionSource
    private var hasLoaded = false

    public init(roster: any MachineRoster, sessions: any MachineSessionSource) {
        self.roster = roster
        self.sessions = sessions
    }

    /// 取一遍名册：在线的在前，同档按名字。取失败时保留已有的名册，从没取到过才算失败。
    /// 名册取到后，各在线机器再各问一次它现算的会话计数。
    /// 进屏载入与下拉刷新会叠在一起：先发的那次晚到时（某台机器的计数要等到中继期限），不盖掉后发那次已落下的。
    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let fetched = try await roster.machines()
            guard generation == loadGeneration else { return }
            machines = fetched.sorted { lhs, rhs in
                if lhs.online != rhs.online { return lhs.online }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            hasLoaded = true
            loadFailed = false
            failure = nil
            await loadCounts(generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            loadFailed = !hasLoaded
            failure = hasLoaded ? nil : FailureFact(presenting: error)
        }
    }

    private var loadGeneration = 0

    private func loadCounts(generation: Int) async {
        let online = machines.filter(\.online)
        let sessions = sessions
        var updated: [String: MachineSessionCounts] = [:]
        await withTaskGroup(of: (String, MachineSessionCounts?).self) { group in
            for machine in online {
                group.addTask { (machine.fingerprint, try? await sessions.counts(on: machine.fingerprint)) }
            }
            for await (fingerprint, counts) in group where counts != nil {
                updated[fingerprint] = counts
            }
        }
        guard generation == loadGeneration else { return }
        counts = updated
    }
}
