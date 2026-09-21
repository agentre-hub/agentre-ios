import Foundation

/// 一个可选的模型：供应商键 + 模型键（SetModelTargetRequest 的两格）。
public struct ComposerModelChoice: Sendable, Equatable, Hashable {
    public var providerKey: String
    public var modelKey: String

    public init(providerKey: String, modelKey: String) {
        self.providerKey = providerKey
        self.modelKey = modelKey
    }
}

/// 面板上三项的当前取值与可选范围。
public struct ComposerSettings: Sendable, Equatable {
    /// 当前生效的权限档位。
    public var permissionMode: String
    /// 执行端报的可选档位；空 = 这个后端没有权限门。
    public var permissionModes: [String]
    public var model: ComposerModelChoice?
    public var models: [ComposerModelChoice]
    /// 会话行上的思考档位；空 = 跟随后端配置。
    public var reasoningEffort: String
    /// 后端配置的档位，会话行为空时由它兜底；空 = 后端也没配。
    public var backendReasoningEffort: String

    /// 五个档位，从弱到强，与宿主 reasoning-effort-picker 同一张表。
    public static let reasoningEffortLevels = ["low", "medium", "high", "xhigh", "max"]

    public init(
        permissionMode: String = "", permissionModes: [String] = [], model: ComposerModelChoice? = nil, models: [ComposerModelChoice] = [],
        reasoningEffort: String = "", backendReasoningEffort: String = ""
    ) {
        self.permissionMode = permissionMode
        self.permissionModes = permissionModes
        self.model = model
        self.models = models
        self.reasoningEffort = reasoningEffort
        self.backendReasoningEffort = backendReasoningEffort
    }

    /// 一条会话的面板取值：当前模型与思考档位取自会话行（机器的清单原样），权限档位与两份可选范围
    /// 由调用方从执行端与引擎目录问来。会话行上没有模型时当前模型留空，不编。
    public init(conversation: SavedConversation, permissionMode: String, permissionModes: [String], models: [ComposerModelChoice]) {
        self.init(
            permissionMode: permissionMode, permissionModes: permissionModes,
            model: conversation.modelKey.isEmpty ? nil : ComposerModelChoice(providerKey: conversation.providerKey, modelKey: conversation.modelKey),
            models: models, reasoningEffort: conversation.reasoningEffort
        )
    }

    /// 起手的权限档位（用户这次还没选时）：转录里执行端最后报过的当前档，它须在这台机器报的可选范围里
    /// 才算数；否则是执行端报的默认档。与控制台 SessionDetailView 的起手值同一取法：不校验范围的话，
    /// 一档别的后端才有的档位会随每一轮 runtime.run 过线，被执行端整轮顶回来。
    public static func startingPermissionMode(reported: String?, allowed: [String], defaultMode: String) -> String {
        guard let reported, !reported.isEmpty, allowed.contains(reported) else { return defaultMode }
        return reported
    }

    /// 有效档位：会话行上的值非空时是它，为空时是后端配置的档位；都空时是空（界面标注「默认」）。
    public var effectiveReasoningEffort: String { reasoningEffort.isEmpty ? backendReasoningEffort : reasoningEffort }
}
