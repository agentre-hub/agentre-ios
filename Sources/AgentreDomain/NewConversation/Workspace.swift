import Foundation

/// 执行目标链上一档此刻能不能接活（agentre-server `/v1/workspace/*` 的 availability 字段）。
public enum TargetAvailability: Sendable, Hashable {
    case available
    case offline
    case unpaired
    /// 这一档没指定设备。
    case noDevice
    /// 选了项目，而这台机器上没配这个项目的路径。
    case projectPathMissing
    /// 服务端报了一个这个版本不认得的取值：按不可用对待。
    case unrecognized(String)

    public init(wire value: String) {
        switch value {
        case "available": self = .available
        case "offline": self = .offline
        case "unpaired": self = .unpaired
        case "no_device": self = .noDevice
        case "project_path_missing": self = .projectPathMissing
        default: self = .unrecognized(value)
        }
    }

    public var isAvailable: Bool { self == .available }
}

/// Agent 执行目标链上的一档（账号默认顺序）。
public struct ExecTarget: Sendable, Equatable {
    public var rank: Int
    public var backendSyncID: String
    /// 「本机」相对档：说不出是哪台机器。
    public var deviceUnspecified: Bool
    public var deviceName: String
    public var backendType: String
    public var availability: TargetAvailability
    /// 自动解析此刻落到的那一档。
    public var current: Bool

    public init(
        rank: Int, backendSyncID: String = "", deviceUnspecified: Bool = false, deviceName: String = "",
        backendType: String = "", availability: TargetAvailability, current: Bool = false
    ) {
        self.rank = rank
        self.backendSyncID = backendSyncID
        self.deviceUnspecified = deviceUnspecified
        self.deviceName = deviceName
        self.backendType = backendType
        self.availability = availability
        self.current = current
    }
}

/// 账号级 Agent 清单的一项。
public struct WorkspaceAgent: Sendable, Equatable, Identifiable {
    public var syncID: String
    public var name: String
    /// 直接加入的项目；继承由客户端按项目树算（`ProjectMembership`）。
    public var projectSyncIDs: [String]
    public var execTargets: [ExecTarget]
    public var hasAvailableTarget: Bool
    /// 头像字形的身份色（服务端 `avatar_color`）；缺失或不在 `agent-1…agent-16` 之内即中性。
    public var avatarColor: IdentityColor

    public var id: String { syncID }

    public init(
        syncID: String, name: String, projectSyncIDs: [String] = [], execTargets: [ExecTarget] = [], hasAvailableTarget: Bool,
        avatarColor: IdentityColor = .neutral
    ) {
        self.syncID = syncID
        self.name = name
        self.projectSyncIDs = projectSyncIDs
        self.execTargets = execTargets
        self.hasAvailableTarget = hasAvailableTarget
        self.avatarColor = avatarColor
    }
}

/// 账号项目树上的一个节点。
public struct WorkspaceProject: Sendable, Equatable, Identifiable {
    public var syncID: String
    public var name: String
    /// nil 即根项目。
    public var parentSyncID: String?
    public var sortOrder: Int
    /// 头像字形的身份色（服务端 `color`）；缺失或不在 `agent-1…agent-16` 之内即中性。
    public var color: IdentityColor

    public var id: String { syncID }

    public init(syncID: String, name: String, parentSyncID: String? = nil, sortOrder: Int = 0, color: IdentityColor = .neutral) {
        self.syncID = syncID
        self.name = name
        self.parentSyncID = parentSyncID
        self.sortOrder = sortOrder
        self.color = color
    }
}

/// 派发计划里逐档的一行。
public struct DispatchTier: Sendable, Equatable, Identifiable {
    public var rank: Int
    /// 这一档跨机稳定且逐档唯一的标识：手动指定挑的就是它。
    public var backendSyncID: String
    public var deviceName: String
    public var backendType: String
    /// 设备种类（desktop / agentred）；说不出机器的档为空。
    public var kind: String
    public var availability: TargetAvailability

    public var id: Int { rank }

    public init(rank: Int, backendSyncID: String = "", deviceName: String = "", backendType: String = "", kind: String = "", availability: TargetAvailability) {
        self.rank = rank
        self.backendSyncID = backendSyncID
        self.deviceName = deviceName
        self.backendType = backendType
        self.kind = kind
        self.availability = availability
    }
}

/// 派发最终落到的那一档。
public struct DispatchChoice: Sendable, Equatable {
    public var deviceFingerprint: String
    public var deviceName: String
    public var backendSyncID: String
    public var backendType: String
    public var kind: String
    /// 项目在那台机器上的工作目录；不指定项目时为空。
    public var cwd: String

    public init(deviceFingerprint: String, deviceName: String, backendSyncID: String = "", backendType: String, kind: String = "", cwd: String = "") {
        self.deviceFingerprint = deviceFingerprint
        self.deviceName = deviceName
        self.backendSyncID = backendSyncID
        self.backendType = backendType
        self.kind = kind
        self.cwd = cwd
    }

    /// Pi 后端不提供权限模式这一项：它的 `permission_mode` 在派发时承载归属令牌（`RelayDispatcher`）。
    public var offersPermissionMode: Bool { backendType != "piagent" }

    /// 同一台机器上的同一个后端：工具行的候选随它而定，它变了草稿上选的三项才作废。
    public func isSameTarget(as other: DispatchChoice?) -> Bool {
        guard let other else { return false }
        return deviceFingerprint == other.deviceFingerprint && backendSyncID == other.backendSyncID && backendType == other.backendType
    }
}

/// 某 Agent（+ 可选项目 + 可选手动指定的一档）的派发计划。
public struct DispatchPlan: Sendable, Equatable {
    public var agentSyncID: String
    public var tiers: [DispatchTier]
    /// nil = 没有一档跑得了（手动指定的那一档跑不了时也是 nil，不回落到自动挑）。
    public var chosen: DispatchChoice?

    public init(agentSyncID: String, tiers: [DispatchTier], chosen: DispatchChoice?) {
        self.agentSyncID = agentSyncID
        self.tiers = tiers
        self.chosen = chosen
    }
}

/// 某个项目下一个 Agent 此刻落到哪（「从项目里挑」每行的副行）：取自带项目问到的派发计划。
public enum ProjectLanding: Sendable, Equatable {
    case landsOn(device: String, cwd: String)
    /// 跑不了：第一档说得出机器的不可用档（说不出时取第一档不可用档，机器名为空）与原因。
    case unavailable(device: String, reason: TargetAvailability)
    case noTarget
}

extension DispatchPlan {
    public var landing: ProjectLanding {
        if let chosen { return .landsOn(device: chosen.deviceName, cwd: chosen.cwd) }
        let blocked = tiers.filter { !$0.availability.isAvailable }
        guard let blocking = blocked.first(where: { !$0.deviceName.isEmpty }) ?? blocked.first else { return .noTarget }
        return .unavailable(device: blocking.deviceName, reason: blocking.availability)
    }
}

public struct DispatchPlanQuery: Sendable, Hashable {
    public var agentSyncID: String
    /// nil = 不指定项目。
    public var projectSyncID: String?
    /// nil = 按次序自动挑。
    public var targetBackendSyncID: String?

    public init(agentSyncID: String, projectSyncID: String? = nil, targetBackendSyncID: String? = nil) {
        self.agentSyncID = agentSyncID
        self.projectSyncID = projectSyncID
        self.targetBackendSyncID = targetBackendSyncID
    }
}

/// 新建对话要问服务端的三件事（只读）。
public protocol WorkspaceService: Sendable {
    func agents() async throws -> [WorkspaceAgent]
    func projects() async throws -> [WorkspaceProject]
    func dispatchPlan(_ query: DispatchPlanQuery) async throws -> DispatchPlan
}
