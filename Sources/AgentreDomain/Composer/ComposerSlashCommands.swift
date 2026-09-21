import Foundation

// 斜杠命令的清单，规则移植自宿主 agentre-ui/src/chat-input/slash/registry.ts 与 filter.ts。
// 选中之后只把字面文本填回输入框；`/compact` 在 CLI 不认它的后端上由发送那一处转成压缩调用。

public struct SlashCommand: Sendable, Equatable, Identifiable {
    public enum Builtin: String, Sendable {
        case compact
        case goal
    }

    public enum Origin: Sendable, Equatable {
        case builtin(Builtin)
        /// 从这个后端的 Skill 目录翻来的。
        case skill(backendType: String)
    }

    public var name: String
    public var trigger: Character
    public var origin: Origin
    /// 已是可读文案（同时参与副标题评分）。
    public var description: String
    /// 选中后填回输入框的字面文本。
    public var insertion: String

    public var label: String { "\(trigger)\(name)" }
    public var id: String { label }
}

public enum SlashCommands {
    /// CLI 自己认 `/compact` 的后端。
    private static let nativeCompactBackends: Set<String> = ["claudecode"]
    /// 摆得出 `/compact` 的后端。
    private static let compactBackends: Set<String> = ["claudecode", "codex", "piagent"]

    /// 这个后端的 CLI 自己认 `/compact` 吗；不认的要由宿主转成一次压缩调用。
    public static func isNativeCompact(backendType: String) -> Bool {
        nativeCompactBackends.contains(backendType)
    }

    /// Skill 的触发字符：Claude Code 与 Pi 用 `/`，Codex 用 `$`；没有 Skill 一说的后端为 nil。
    public static func skillPrefix(backendType: String) -> Character? {
        switch backendType {
        case "claudecode", "piagent": "/"
        case "codex": "$"
        default: nil
        }
    }

    /// 当前后端下真的可用的命令：内置在前、Skill 在后；触发字符与名字都相同才算重名，先出现的赢。
    /// 后端还不知道时一条都不列。
    public static func available(backendType: String, skills: [ComposerSkillSource], describe: (SlashCommand.Origin) -> String) -> [SlashCommand] {
        guard !backendType.isEmpty else { return [] }
        var commands: [SlashCommand] = []
        if compactBackends.contains(backendType) {
            commands.append(SlashCommand(name: "compact", trigger: "/", origin: .builtin(.compact), description: describe(.builtin(.compact)), insertion: "/compact"))
        }
        if backendType == "codex" {
            // 尾随空格是有意的：选中之后光标停在参数位上。
            commands.append(SlashCommand(name: "goal", trigger: "/", origin: .builtin(.goal), description: describe(.builtin(.goal)), insertion: "/goal "))
        }
        if let trigger = skillPrefix(backendType: backendType) {
            let origin = SlashCommand.Origin.skill(backendType: backendType)
            let fallback = describe(origin)
            for source in skills {
                var name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.first == trigger { name = String(name.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !name.isEmpty else { continue }
                let description = source.description.trimmingCharacters(in: .whitespacesAndNewlines)
                commands.append(SlashCommand(
                    name: name, trigger: trigger, origin: origin,
                    description: description.isEmpty ? fallback : description, insertion: "\(trigger)\(name)"
                ))
            }
        }
        var seen = Set<String>()
        return commands.filter { seen.insert($0.label).inserted }
    }

    /// 只留当前触发字符的命令，按名字（副标题取说明）评分排序；同分维持源顺序。
    public static func filter(_ commands: [SlashCommand], query: String, trigger: Character) -> [SlashCommand] {
        let scored: [(command: SlashCommand, index: Int, score: Int)] = commands.enumerated().map { index, command in
            let score = command.trigger == trigger ? SuggestionScore.score(query: query, title: command.name, subtitle: command.description) : 0
            return (command, index, score)
        }
        return scored
            .filter { $0.score > 0 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.command)
    }
}
