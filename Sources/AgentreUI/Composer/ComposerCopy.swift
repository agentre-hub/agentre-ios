import AgentreDomain
import Foundation

let composerTable = "Composer"

/// 输入区自己的几句文案，给不经过视图的地方（斜杠命令的说明同时参与副标题评分）。按传入的语言解析：
/// 候选先排成字符串，不随视图环境的语言再解析一次。
enum ComposerCopy {
    static func describe(_ origin: SlashCommand.Origin, locale: Locale) -> String {
        let key: String.LocalizationValue = switch origin {
        case .builtin(.compact): "composer.slash.compact"
        case .builtin(.goal): "composer.slash.goal"
        case .skill(let backend) where backend == "codex": "composer.slash.codexSkill"
        case .skill(let backend) where backend == "piagent": "composer.slash.piSkill"
        case .skill: "composer.slash.claudeSkill"
        }
        return LocalizedCopy(key, table: composerTable).resolved(in: locale)
    }
}
