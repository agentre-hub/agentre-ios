import AgentreDomain
import Foundation

let composerTable = "Composer"

/// 输入区自己的几句文案，给不经过视图的地方（斜杠命令的说明同时参与副标题评分）。
enum ComposerCopy {
    static func describe(_ origin: SlashCommand.Origin) -> String {
        switch origin {
        case .builtin(.compact): String(localized: "composer.slash.compact", table: composerTable, bundle: .module)
        case .builtin(.goal): String(localized: "composer.slash.goal", table: composerTable, bundle: .module)
        case .skill(let backend) where backend == "codex": String(localized: "composer.slash.codexSkill", table: composerTable, bundle: .module)
        case .skill(let backend) where backend == "piagent": String(localized: "composer.slash.piSkill", table: composerTable, bundle: .module)
        case .skill: String(localized: "composer.slash.claudeSkill", table: composerTable, bundle: .module)
        }
    }
}
