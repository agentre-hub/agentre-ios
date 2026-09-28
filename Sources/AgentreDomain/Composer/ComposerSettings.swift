import Foundation

/// 一个可选的模型：供应商键 + 模型键（SetModelTargetRequest 的两格），外加引擎目录里给人读的三格
/// （模型展示名、模型 ID、供应商名）。下发只用两枚键；人读的几格只供界面标注，目录里查不到时为空。
public struct ComposerModelChoice: Sendable, Equatable, Hashable {
    public var providerKey: String
    public var modelKey: String
    public var modelId: String
    public var name: String
    public var providerName: String

    public init(providerKey: String, modelKey: String, modelId: String = "", name: String = "", providerName: String = "") {
        self.providerKey = providerKey
        self.modelKey = modelKey
        self.modelId = modelId
        self.name = name
        self.providerName = providerName
    }

    /// 模型的人读名：展示名 → 模型 ID → 模型键（宿主 modelDisplayName 同序，最后一档是目录里查不到时的原始键）。
    public var displayName: String {
        if !name.isEmpty { return name }
        return modelId.isEmpty ? modelKey : modelId
    }

    /// 「供应商 · 模型」的人读摘要，与宿主 resolveTargetLabel 同形：供应商名缺失回落供应商键，两者都缺时只剩模型。
    public var label: String {
        let provider = providerName.isEmpty ? providerKey : providerName
        return provider.isEmpty ? displayName : "\(provider) · \(displayName)"
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
    /// 会话行上的思考档位；空 = 跟随后端配置（界面标注「默认」：手机拿不到后端配的是哪一档）。
    public var reasoningEffort: String

    /// 五个档位，从弱到强，与宿主 reasoning-effort-picker 同一张表。
    public static let reasoningEffortLevels = ["low", "medium", "high", "xhigh", "max"]

    public init(
        permissionMode: String = "", permissionModes: [String] = [], model: ComposerModelChoice? = nil, models: [ComposerModelChoice] = [],
        reasoningEffort: String = ""
    ) {
        self.permissionMode = permissionMode
        self.permissionModes = permissionModes
        self.model = model
        self.models = models
        self.reasoningEffort = reasoningEffort
    }

    /// 一条会话的面板取值：当前模型与思考档位取自会话行（机器的清单原样，模型再到目录里认出可读名），权限档位与两份可选范围
    /// 由调用方从执行端与引擎目录问来。会话行上没有模型时当前模型留空，不编。
    public init(conversation: SavedConversation, permissionMode: String, permissionModes: [String], models: [ComposerModelChoice]) {
        self.init(
            permissionMode: permissionMode, permissionModes: permissionModes,
            model: Self.savedModel(of: conversation, in: models), models: models, reasoningEffort: conversation.reasoningEffort
        )
    }

    /// 会话行上钉的模型，在引擎目录里认出可读名；会话行上没有模型时为空，不编。
    public static func savedModel(of conversation: SavedConversation, in models: [ComposerModelChoice]) -> ComposerModelChoice? {
        conversation.modelKey.isEmpty ? nil : resolve(providerKey: conversation.providerKey, modelKey: conversation.modelKey, in: models)
    }

    /// 会话行上的两枚键在引擎目录里认出那一项（带人读名）；目录里没有时只剩两枚键，界面据此回落原始键。
    private static func resolve(providerKey: String, modelKey: String, in models: [ComposerModelChoice]) -> ComposerModelChoice {
        models.first { $0.providerKey == providerKey && $0.modelKey == modelKey }
            ?? ComposerModelChoice(providerKey: providerKey, modelKey: modelKey)
    }

    /// 起手的权限档位（用户这次还没选时）：转录里执行端最后报过的当前档，它须在这台机器报的可选范围里
    /// 才算数；否则是执行端报的默认档。与控制台 SessionDetailView 的起手值同一取法：不校验范围的话，
    /// 一档别的后端才有的档位会随每一轮 runtime.run 过线，被执行端整轮顶回来。
    public static func startingPermissionMode(reported: String?, allowed: [String], defaultMode: String) -> String {
        guard let reported, !reported.isEmpty, allowed.contains(reported) else { return defaultMode }
        return reported
    }
}
