import AgentreDomain
import Testing

/// 斜杠命令的清单，规则对齐宿主 chat-input/slash/registry.ts 与 filter.ts。
@Suite("斜杠命令清单")
struct SlashCommandTests {
    let describe: @Sendable (SlashCommand.Origin) -> String = { origin in
        switch origin {
        case .builtin(let builtin): "builtin:\(builtin.rawValue)"
        case .skill: "skill"
        }
    }

    func names(_ commands: [SlashCommand]) -> [String] { commands.map(\.label) }

    @Test("backend 还不知道时一条都不列")
    func unknownBackend() {
        #expect(SlashCommands.available(backendType: "", skills: [ComposerSkillSource(name: "x")], describe: describe).isEmpty)
    }

    @Test("claudecode：/compact 在前，Skill 用 / 且在后；codex：/compact、/goal，Skill 用 $；没有 Skill 一说的后端只列它支持的内置命令")
    func perBackend() {
        let skills = [ComposerSkillSource(name: "deploy", description: "上线")]
        #expect(names(SlashCommands.available(backendType: "claudecode", skills: skills, describe: describe)) == ["/compact", "/deploy"])
        #expect(names(SlashCommands.available(backendType: "codex", skills: skills, describe: describe)) == ["/compact", "/goal", "$deploy"])
        #expect(names(SlashCommands.available(backendType: "piagent", skills: skills, describe: describe)) == ["/compact", "/deploy"])
        #expect(names(SlashCommands.available(backendType: "gemini", skills: skills, describe: describe)).isEmpty)
    }

    @Test("Skill：前缀只加一次、空名与重名丢弃、没有说明时取后端兜底；内置 /compact 压过同名 Skill")
    func skillCatalog() {
        let skills = [
            ComposerSkillSource(name: "/review"), ComposerSkillSource(name: "review"), ComposerSkillSource(name: "  "),
            ComposerSkillSource(name: "compact", description: "别的"),
        ]
        let commands = SlashCommands.available(backendType: "claudecode", skills: skills, describe: describe)
        #expect(names(commands) == ["/compact", "/review"])
        #expect(commands[0].description == "builtin:compact")
        #expect(commands[1].description == "skill")
        #expect(commands[1].insertion == "/review")
        #expect(SlashCommands.available(backendType: "codex", skills: [], describe: describe)[1].insertion == "/goal ")
    }

    @Test("按 query 过滤并排序，只认当前触发字符；空 query 保持原序")
    func filter() {
        let commands = SlashCommands.available(backendType: "codex", skills: [ComposerSkillSource(name: "goal-review")], describe: describe)
        #expect(names(SlashCommands.filter(commands, query: "", trigger: "/")) == ["/compact", "/goal"])
        #expect(names(SlashCommands.filter(commands, query: "goal", trigger: "$")) == ["$goal-review"])
        #expect(names(SlashCommands.filter(commands, query: "go", trigger: "/")) == ["/goal"])
    }

    @Test("只有 claudecode 的 CLI 自己认 /compact")
    func nativeCompact() {
        #expect(SlashCommands.isNativeCompact(backendType: "claudecode"))
        #expect(!SlashCommands.isNativeCompact(backendType: "codex"))
    }
}
