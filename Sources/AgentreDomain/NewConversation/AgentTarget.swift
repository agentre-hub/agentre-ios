import Foundation

/// 选 Agent 那屏每行尾部那句：解析结果，不是选择器。
public enum AgentTargetSummary: Sendable, Equatable {
    /// 当前落到这台机器。
    case landsOn(device: String)
    /// 当前落到「本机」相对档。
    case landsOnThisDevice
    /// 跑不了：第一档说得出原因的那一档的机器名（说不出时为空）与原因。
    case unavailable(device: String, reason: TargetAvailability)
    /// 链是空的，或说不出任何原因。
    case noTarget
}

extension WorkspaceAgent {
    /// 可用时说当前落到哪；跑不了时给第一档说得出原因的那一档——「本机」相对档在手机语境下
    /// 永远跳过，拿它当理由等于每个 Agent 都写着同一句话，除非链上只剩它。
    public var targetSummary: AgentTargetSummary {
        if hasAvailableTarget {
            guard let current = execTargets.first(where: \.current) ?? execTargets.first(where: \.availability.isAvailable) else {
                return .noTarget
            }
            return current.deviceUnspecified ? .landsOnThisDevice : .landsOn(device: current.deviceName)
        }
        guard let blocking = execTargets.first(where: { !$0.availability.isAvailable && !$0.deviceUnspecified })
            ?? execTargets.first
        else { return .noTarget }
        return .unavailable(device: blocking.deviceName, reason: blocking.availability)
    }
}

/// 「最近用过」：本地库里最近活动过的会话所属的 Agent，去重、新的在前。
public enum RecentAgents {
    public static let limit = 3

    public static func pick(from conversations: [SavedConversation], agents: [WorkspaceAgent], limit: Int = limit) -> [WorkspaceAgent] {
        let byID = Dictionary(agents.map { ($0.syncID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var picked: [WorkspaceAgent] = []
        for conversation in conversations.sorted(by: { $0.lastMessageAt > $1.lastMessageAt }) where picked.count < limit {
            guard let agent = byID[conversation.agentSyncID], seen.insert(agent.syncID).inserted else { continue }
            picked.append(agent)
        }
        return picked
    }
}
