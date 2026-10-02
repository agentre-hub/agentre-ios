import Foundation

/// 发出第一条消息：经 `machine:<指纹>` 通道在选中的那台机器上开一条新会话（runtime.run）。
public struct DispatchRequest: Sendable, Equatable {
    /// 由手机自己铸的会话号。
    public var conversationID: String
    public var title: String
    public var userText: String
    public var agentSyncID: String
    /// nil = 不指定项目。
    public var projectSyncID: String?
    /// 派发落到的那一档（机器指纹、后端、工作目录）。
    public var target: DispatchChoice
    /// 草稿工具行上选的权限模式、模型、思考档位；一项都没选时三格皆空，按 Agent 与后端的既有配置跑。
    public var settings: ComposerRunSettings

    public init(
        conversationID: String, title: String, userText: String, agentSyncID: String, projectSyncID: String?, target: DispatchChoice,
        settings: ComposerRunSettings = ComposerRunSettings()
    ) {
        self.conversationID = conversationID
        self.title = title
        self.userText = userText
        self.agentSyncID = agentSyncID
        self.projectSyncID = projectSyncID
        self.target = target
        self.settings = settings
    }
}

/// 草稿工具行的候选：按机器 chip 选中的那台机器与后端取。
public struct DraftToolOptions: Sendable, Equatable {
    /// 那台机器上这个后端报的权限档位；空 = 没有权限门（或没问到）。Pi 后端不问。
    public var permissionModes: [String]
    public var models: [ComposerModelChoice]

    public init(permissionModes: [String] = [], models: [ComposerModelChoice] = []) {
        self.permissionModes = permissionModes
        self.models = models
    }
}

/// 草稿工具行的候选从哪来：权限档位问那台机器（runtimeCapabilities），模型取服务端引擎目录。拼装归装配层。
public protocol DraftToolOptionsSource: Sendable {
    func options(for target: DispatchChoice) async throws -> DraftToolOptions
}

/// 派发没成：界面据此用自己的话说，不贴对端原串。
public enum DispatchFailure: Error, Sendable, Equatable {
    /// 连不上那台机器。
    case unreachable
    /// 连上了，但那台机器没能开起这条会话。
    case rejected
    /// 那台机器的协议版本与本 App 不等：要更新 App，重试换不来别的答案。
    case updateRequired
}

/// 中继上的派发（适配器在装配层）。失败以 `DispatchFailure` 抛出；别的错误按 `rejected` 对待。
public protocol NewConversationDispatching: Sendable {
    func dispatch(_ request: DispatchRequest) async throws
}

/// 已经在机器上跑起来的一条新对话：要落进本地库的那一份。
public struct StartedConversation: Sendable, Equatable {
    public var conversationID: String
    /// 承载它的机器。
    public var machineFingerprint: String
    public var machineName: String
    public var title: String
    public var agentSyncID: String
    public var projectSyncID: String
    public var cwd: String
    public var backendType: String
    /// 草稿上选的模型与思考档位：派发收尾已钉到机器的会话行上，本地这一行随之记下（空 = 没选）。
    public var providerKey: String
    public var modelKey: String
    public var reasoningEffort: String

    public init(request: DispatchRequest) {
        conversationID = request.conversationID
        machineFingerprint = request.target.deviceFingerprint
        machineName = request.target.deviceName
        title = request.title
        agentSyncID = request.agentSyncID
        projectSyncID = request.projectSyncID ?? ""
        cwd = request.target.cwd
        backendType = request.target.backendType
        providerKey = request.settings.providerKey
        // 与派发同一条规矩：没选供应商就不钉模型。
        modelKey = request.settings.providerKey.isEmpty ? "" : request.settings.modelKey
        reasoningEffort = request.settings.reasoningEffort
    }
}

/// 把手机上新建的对话落进本地库（规格决策 16；适配器在装配层，落到 `LocalConversationStore`）。
public protocol StartedConversationRecording: Sendable {
    /// 落库并交回它在本地库里的键。
    func record(_ conversation: StartedConversation) async throws -> ConversationKey
}

/// 会话号在发起端铸：UUIDv7（前 48 位 Unix 毫秒，其余取自系统 CSPRNG），规范小写带连字符。
public enum ConversationIDs {
    public static func mint(now: Date = Date()) -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let milliseconds = UInt64(max(0, (now.timeIntervalSince1970 * 1000).rounded()))
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * UInt64(5 - index)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
            .joined(separator: "-")
    }
}

/// 对话标题：第一句话的首行，超过 60 个字符截断加省略号（与控制台、桌面端同一条规矩）。
public func conversationTitle(from text: String) -> String {
    let firstLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first
        .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    return firstLine.count > 60 ? "\(firstLine.prefix(60))…" : firstLine
}
