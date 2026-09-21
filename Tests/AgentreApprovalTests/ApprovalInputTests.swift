import AgentreDomain
import Testing

/// 卡片上那块机器文本的排版：只看工具名与输入的形状（宿主 formatToolSummary 同规则）。
@Suite("审批输入")
struct ApprovalInputTests {
    @Test("Bash：命令按终端排，全文就是命令本身，执行目录原样带上")
    func bashCommand() {
        let input = ApprovalInput(toolName: "Bash", input: ["command": "pnpm test --filter ui", "description": "跑测试"], cwd: "/repo")
        #expect(input.command == "pnpm test --filter ui")
        #expect(input.text == "pnpm test --filter ui")
        #expect(input.summary == "pnpm test --filter ui")
        #expect(input.cwd == "/repo")
        #expect(!input.isLong)
    }

    @Test("别的工具：全文是键按字典序、两格缩进的 JSON；摘要是压成一行的 JSON")
    func otherToolIsIndentedJSON() {
        let input = ApprovalInput(toolName: "Write", input: ["path": "/repo/a.txt", "content": "hi", "opts": ["force": true, "n": 2]], cwd: "")
        #expect(input.command == nil)
        #expect(input.text == """
        {
          "content": "hi",
          "opts": {
            "force": true,
            "n": 2
          },
          "path": "/repo/a.txt"
        }
        """)
        #expect(input.summary == #"{"content":"hi","opts":{"force":true,"n":2},"path":"/repo/a.txt"}"#)
    }

    @Test("摘要只取首行，超过 100 字符截成 97 字符加省略号")
    func summaryIsOneShortLine() {
        let long = String(repeating: "x", count: 150)
        let multiLine = ApprovalInput(toolName: "Bash", input: ["command": .string("cat <<EOF\nline\nEOF")], cwd: "")
        #expect(multiLine.summary == "cat <<EOF")
        let wide = ApprovalInput(toolName: "Bash", input: ["command": .string(long)], cwd: "")
        #expect(wide.summary == String(repeating: "x", count: 97) + "...")
        #expect(wide.text == long)
    }

    @Test("没有输入：全文与摘要都为空；Bash 的 command 不是字符串时按 JSON 排")
    func missingInput() {
        let none = ApprovalInput(toolName: "Bash", input: nil, cwd: "/repo")
        #expect(none.text.isEmpty && none.summary.isEmpty && none.command == nil)
        let odd = ApprovalInput(toolName: "Bash", input: ["command": ["ls", "-la"]], cwd: "")
        #expect(odd.command == nil)
        #expect(odd.text.hasPrefix("{"))
    }

    @Test("过长的判据：超过 6 行或 320 字符", arguments: [
        (String(repeating: "a\n", count: 6) + "a", true),
        (String(repeating: "a\n", count: 5) + "a", false),
        (String(repeating: "y", count: 321), true),
        (String(repeating: "y", count: 320), false),
    ])
    func longness(command: String, long: Bool) {
        #expect(ApprovalInput(toolName: "Bash", input: ["command": .string(command)], cwd: "").isLong == long)
    }
}
