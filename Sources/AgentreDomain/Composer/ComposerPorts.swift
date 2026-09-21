import Foundation

/// 一条插话在执行端的句柄（RuntimeSteerResponse）。`queuedID` 为空 = 对端还没升级到回传句柄的那一版。
public struct ComposerSteerHandle: Sendable, Equatable {
    public var queuedID: String
    public var cancellable: Bool

    public init(queuedID: String, cancellable: Bool) {
        self.queuedID = queuedID
        self.cancellable = cancellable
    }
}

/// 后端取走的一条插话（wire 的 ConsumedSteer，来自 steer_consumed 帧或 runtimeDrainPending）。
public struct ComposerConsumedSteer: Sendable, Equatable {
    public var queuedID: String
    public var text: String

    public init(queuedID: String = "", text: String = "") {
        self.queuedID = queuedID
        self.text = text
    }
}

/// 某台机器答回来的 Skill 目录中的一条（wire 的 SkillCommand：名字不带触发前缀）。
public struct ComposerSkillSource: Sendable, Equatable {
    public var name: String
    public var description: String

    public init(name: String, description: String = "") {
        self.name = name
        self.description = description
    }
}

/// 输入区要走中继的全部调用。一律经 `machine:<承载机指纹>` 通道、以 `conversation_id` 指明对话；
/// 适配器归装配层（任务 12）。方法与 wire 一一对应：
/// runtimeRun / runtimeSteer / runtimeCancelSteer / runtimeDrainPending / runtimeSetPermissionMode /
/// setModelTarget / setSessionReasoningEffort / sessionDelete / skillCommands。
public protocol ComposerRelay: Sendable {
    /// 在这条对话上开新一轮。`compact` 为真时这一轮是一次上下文压缩（RuntimeRunRequest.compact）。
    func run(_ key: ConversationKey, peerFingerprint: String, text: String, compact: Bool) async throws
    /// 一轮运行中插一句话。`queuedID` 是本端铸的号，执行端回显或换成它自己的。
    func steer(_ key: ConversationKey, peerFingerprint: String, queuedID: String, text: String) async throws -> ComposerSteerHandle
    /// 撤回一条排队的插话，交回确实撤掉的句柄。
    func cancelSteer(_ key: ConversationKey, peerFingerprint: String, queuedID: String) async throws -> [String]
    /// 轮末问执行端插话信箱里还剩什么，顺手取走。
    /// nil = 承载机不答这一问（桌面端托管的会话由它自己在轮末接续，不该去抢）。
    func drainPending(_ key: ConversationKey, peerFingerprint: String) async throws -> [ComposerConsumedSteer]?
    func setPermissionMode(_ key: ConversationKey, peerFingerprint: String, mode: String) async throws
    func setModelTarget(_ key: ConversationKey, peerFingerprint: String, providerKey: String, modelKey: String) async throws
    /// 空串是一个要写入的值：改回跟随后端配置。
    func setReasoningEffort(_ key: ConversationKey, peerFingerprint: String, effort: String) async throws
    /// 在承载机上删除这条会话；交回机器是否确实删了一条。
    func deleteSession(_ key: ConversationKey, peerFingerprint: String) async throws -> Bool
    /// 问承载机这一档执行目标此刻叫得动哪些 Skill。`cwd` 是会话的工作目录：项目级 Skill
    /// 只在它下面解析得出来（SkillCommandsRequest.cwd）。授权（SkillAuthorization）由适配器按
    /// Agent 与机器从组织数据里取，与控制台 useSessionSkillCommands 同一口径。
    func skillCommands(machineFingerprint: String, agentSyncID: String, backendType: String, cwd: String) async throws -> [ComposerSkillSource]
}

/// 面板三项的当前取值与可选范围从哪来：权限档位来自执行端的 runtimeCapabilities，模型目录来自
/// 服务端的引擎目录，当前模型与思考档位来自会话。拼装归适配器。
public protocol ComposerSettingsSource: Sendable {
    func settings(for conversation: SavedConversation) async throws -> ComposerSettings
}

/// 提及的候选从哪来：账号下的 Agent（`/v1/workspace/agents`）与账号设备（`/v1/devices`），
/// 与控制台 SessionComposer 同一份来路。项目不摆：服务端响应里没有路径，摆上去是空 path 的假引用。
public protocol ComposerMentionSource: Sendable {
    func mentionSources() async throws -> ComposerMentionSources
}
