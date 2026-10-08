import AgentreDomain
import Testing

/// 工具视觉档：逐条移植宿主 agentre-ui/src/transcript/canonical-tool/tier.test.ts。
/// 判据顺序 规范类型 → 输入形状 → 中性兜底，不查工具名表。
@Suite("工具视觉档")
struct ToolTierTests {
    func tool(_ input: [String: JSONValue]? = nil, canonical: Canonical? = nil, name: String = "tool") -> ToolUse {
        ToolUse(id: "t", name: name, input: input, canonical: canonical)
    }

    // ① canonical.kind 命中出组：阻塞用户的卡片永不进组。
    @Test("canonical.kind agent.spawn → out") func agentSpawn() {
        #expect(tool(canonical: Canonical(kind: "agent.spawn")).tier == .out)
    }

    @Test("canonical.kind user.ask → out") func userAsk() {
        #expect(tool(canonical: Canonical(kind: "user.ask", fields: ["requestId": "r1", "questions": []])).tier == .out)
    }

    @Test("canonical.kind plan.approve_request → out") func planApprove() {
        #expect(tool(canonical: Canonical(kind: "plan.approve_request", fields: ["requestId": "r1", "planText": ""])).tier == .out)
    }

    @Test("canonical.kind tool.permission → out") func toolPermission() {
        #expect(tool(canonical: Canonical(kind: "tool.permission", fields: ["requestId": "r1", "toolName": "Bash"])).tier == .out)
    }

    // ② canonical.kind 命中写层。
    @Test("canonical.kind file.write → write") func fileWrite() {
        #expect(tool(canonical: Canonical(kind: "file.write", fields: ["path": "a.ts", "content": "", "lines": 0, "bytes": 0])).tier == .write)
    }

    @Test("canonical.kind file.edit → write") func fileEdit() {
        #expect(tool(canonical: Canonical(kind: "file.edit", fields: ["files": []])).tier == .write)
    }

    // ③ 无 canonical 时按 input shape 探测。
    @Test("input.command present (no canonical) → write") func command() {
        #expect(tool(["command": "ls -la"]).tier == .write)
    }

    @Test("input.cmd present (no canonical) → write") func cmd() {
        #expect(tool(["cmd": "echo hi"]).tier == .write)
    }

    @Test("input.content present (no canonical) → write") func content() {
        #expect(tool(["content": "hello"]).tier == .write)
    }

    @Test("input.edits present (no canonical) → write") func edits() {
        #expect(tool(["edits": [["oldText": "a", "newText": "b"]]]).tier == .write)
    }

    @Test("input.old_string present (no canonical) → write") func oldString() {
        #expect(tool(["old_string": "a", "new_string": "b"]).tier == .write)
    }

    @Test("input.path present (no canonical) → read") func path() {
        #expect(tool(["path": "/tmp/a.ts"]).tier == .read)
    }

    // 定位语义字段与 summary 的 PATH_KEYS 同源 —— claudecode 的 Read 用 file_path。
    @Test("input.file_path present (no canonical) → read") func filePath() {
        #expect(tool(["file_path": "/tmp/a.ts", "limit": 20, "offset": 0]).tier == .read)
    }

    @Test("input.file / input.filename present (no canonical) → read") func fileAndFilename() {
        #expect(tool(["file": "/tmp/a.ts"]).tier == .read)
        #expect(tool(["filename": "a.ts"]).tier == .read)
    }

    // 写入语义字段先于定位字段命中：Write 的 {file_path, content} 仍是写层。
    @Test("write-shaped input wins over a co-present locator field") func writeWinsOverLocator() {
        #expect(tool(["content": "x", "file_path": "/tmp/a.ts"]).tier == .write)
    }

    @Test("input.pattern present (no canonical) → read") func pattern() {
        #expect(tool(["pattern": "*.ts"]).tier == .read)
    }

    @Test("input.query present (no canonical) → read") func query() {
        #expect(tool(["query": "foo"]).tier == .read)
    }

    @Test("input.url present (no canonical) → read") func url() {
        #expect(tool(["url": "https://example.com"]).tier == .read)
    }

    // ④ 都不匹配落中性层 —— 认不出来的工具不假装它是只读。
    @Test("unrecognized shape (no canonical, no known keys) → neutral, not read") func unrecognized() {
        #expect(tool(["foo": "bar"]).tier == .neutral)
    }

    @Test("no canonical and no toolInput at all → neutral") func nothing() {
        #expect(tool().tier == .neutral)
    }

    @Test("empty toolInput object → neutral") func emptyInput() {
        #expect(tool([:]).tier == .neutral)
    }

    // 顺序：canonical.kind 优先于 input shape。
    @Test("canonical.kind out-group wins over write-shaped input") func outWinsOverShape() {
        #expect(tool(["command": "rm -rf /"], canonical: Canonical(kind: "tool.permission", fields: ["requestId": "r1", "toolName": "Bash"])).tier == .out)
    }

    // 宿主的 hasAnyKey 判 `input[k] != null`：值为 null 的键不算命中。
    @Test("a null-valued key does not count as present") func nullKey() {
        #expect(tool(["command": .null]).tier == .neutral)
    }

    // 不查工具名表：名字像只读也不算。
    @Test("the tool name alone never decides the tier") func nameIsIgnored() {
        #expect(tool(["foo": "bar"], name: "Read").tier == .neutral)
        #expect(tool(["foo": "bar"], name: "Bash").tier == .neutral)
    }

    // toolCategory：写层内部再分「改文件 / 写入 / 命令」，判据顺序与 tier 一致。
    @Test("category splits the write tier by canonical kind, then by command shape") func category() {
        #expect(tool(canonical: Canonical(kind: "file.edit", fields: ["files": []])).category == .edit)
        #expect(tool(canonical: Canonical(kind: "file.write")).category == .write)
        #expect(tool(["command": "ls"]).category == .command)
        #expect(tool(["content": "x"]).category == .write)
        #expect(tool(["path": "a"]).category == .read)
        #expect(tool(["foo": "bar"]).category == .other)
        #expect(tool(canonical: Canonical(kind: "agent.spawn")).category == .other)
    }
}

@Suite("displayName")
struct DisplayNameTests {
    @Test("mcp__server__tool → \"server · tool\"") func mcp() {
        #expect(ToolUse.displayName("mcp__github__create_issue") == "github · create_issue")
    }

    @Test("mcp__server__tool with underscores in tool name keeps them") func underscores() {
        #expect(ToolUse.displayName("mcp__playwright__browser_click") == "playwright · browser_click")
    }

    @Test("plain tool name passes through unchanged") func plain() {
        #expect(ToolUse.displayName("Bash") == "Bash")
    }

    @Test("name that merely starts with mcp__ but has no third segment passes through unchanged") func noThird() {
        #expect(ToolUse.displayName("mcp__onlyserver") == "mcp__onlyserver")
    }
}
