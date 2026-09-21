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

    private let roster: any MachineRoster
    private var hasLoaded = false

    public init(roster: any MachineRoster) {
        self.roster = roster
    }

    /// 取一遍名册：在线的在前，同档按名字。取失败时保留已有的名册，从没取到过才算失败。
    public func load() async {
        do {
            machines = try await roster.machines().sorted { lhs, rhs in
                if lhs.online != rhs.online { return lhs.online }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            hasLoaded = true
            loadFailed = false
        } catch {
            loadFailed = !hasLoaded
        }
    }
}
