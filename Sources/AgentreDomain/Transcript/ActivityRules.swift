import Foundation

// 活动块汇总与一步的事实，移植自宿主 agentre-ui 的 transcript-rows.ts（summarizeActivity /
// isFailedStep / isBackgroundRunningBlock）、canonical-tool/command-result.ts 与
// activity-block/facts.ts。组头计数与展开后的行标记共用这里的同一个判据。

/// 命令类工具的结果：`{exitCode, output, status}`。靠结果形状判定，不靠工具名。
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int?
    public var output: String
    public var status: String?

    public init?(parsing text: String) {
        guard let object = JSONValue(json: text)?.object else { return nil }
        guard object["output"] != nil || object["exitCode"] != nil || object["status"] != nil else { return nil }
        exitCode = object["exitCode"]?.int
        status = object["status"]?.string
        switch object["output"] {
        case nil, .null?: output = ""
        case .string(let value)?: output = value
        case let other?: output = other.compactText
        }
    }

    /// 退出码非零，或状态是 failed / error / interrupted。
    public var isFailed: Bool {
        if let exitCode, exitCode != 0 { return true }
        return status == "failed" || status == "error" || status == "interrupted"
    }
}

public enum ActivityRules {
    /// 组头最多列这么多类，再多的折成一个省略号。
    public static let summaryMaxParts = 4

    /// 「这一步失败了没有」的唯一判据。没有结果的一步只有在调用方声明这一轮已以失败终结时才算失败；
    /// 有结果时错误标志只是信号之一 —— 命令把退出码写在结果里，一条 exit 1 的命令错误标志可以是 false。
    public static func isFailed(_ step: ActivityStep, unresolvedFailed: Bool = false) -> Bool {
        guard case .tool(_, _, let result) = step else { return false }
        guard let result else { return unresolvedFailed }
        return result.isError || (CommandResult(parsing: result.text)?.isFailed ?? false)
    }

    /// 一步是不是「run_in_background 的命令，此刻还在跑」。结果是启动回执，不能靠有没有结果判；
    /// 看后台任务的状态，终态之外（含状态缺失 = 刚派出去）一律算还在跑。
    public static func isBackgroundRunning(_ use: ToolUse?) -> Bool {
        guard let use, use.input?["run_in_background"] == .bool(true) else { return false }
        let status = use.subagent?.status
        return status != "completed" && status != "failed" && status != "canceled"
    }

    /// 汇总组头：类目按固定顺序输出并截断，改文件额外报出规模，失败与后台计数单列且不参与截断。
    public static func summarize(_ steps: [ActivityStep], unresolvedFailed: Bool = false) -> ActivitySummary {
        var counts: [ActivityCategory: Int] = [:]
        var editedPaths = Set<String>()
        var plus = 0
        var minus = 0
        var failures = 0
        var backgroundRunning = 0

        for step in steps {
            guard case .tool(_, let use, _) = step else {
                counts[.thinking, default: 0] += 1
                continue
            }
            counts[ActivityCategory(use.category), default: 0] += 1
            for patch in use.canonical?.editedFiles ?? [] {
                editedPaths.insert(patch.path)
                plus += patch.plus
                minus += patch.minus
            }
            if isFailed(step, unresolvedFailed: unresolvedFailed) { failures += 1 }
            if isBackgroundRunning(use) { backgroundRunning += 1 }
        }

        let all = ActivityCategory.allCases.compactMap { category -> ActivitySummaryPart? in
            guard let count = counts[category] else { return nil }
            return category == .edit
                ? ActivitySummaryPart(category: category, count: count, files: editedPaths.count, plus: plus, minus: minus)
                : ActivitySummaryPart(category: category, count: count)
        }
        return ActivitySummary(
            steps: steps.count,
            parts: Array(all.prefix(summaryMaxParts)),
            truncated: all.count > summaryMaxParts,
            failures: failures,
            backgroundRunning: backgroundRunning
        )
    }
}

extension ActivityCategory {
    init(_ category: ToolCategory) {
        switch category {
        case .read: self = .read
        case .edit: self = .edit
        case .write: self = .write
        case .command: self = .command
        case .other: self = .other
        }
    }
}

extension ActivityStep {
    /// 行首摘要的长度上限。
    static let summaryMaxCharacters = 200

    /// 这一步可报出来的事实。`pendingOutcome` 是没有结果时的归属（默认运行中）。
    public func facts(pendingOutcome: PendingOutcome = .running) -> StepFacts {
        var facts = StepFacts()
        switch self {
        case .thinking(_, let text):
            facts.resultText = text
            return facts
        case .tool(_, let use, let result):
            let command = result.flatMap { CommandResult(parsing: $0.text) }
            facts.resultText = command?.output ?? result?.text ?? ""
            facts.pending = result == nil ? pendingOutcome : nil
            if let code = command?.exitCode, code != 0 { facts.exitCode = code }
            facts.failed = ActivityRules.isFailed(self, unresolvedFailed: pendingOutcome == .failed)
            if ActivityRules.isBackgroundRunning(use) {
                facts.backgroundRunning = true
                facts.backgroundTaskID = use.subagent?.taskID.isEmpty == false ? use.subagent?.taskID : nil
            }
            facts.result = facts.failed ? .failed : Self.result(of: use, text: result.map { _ in facts.resultText })
            return facts
        }
    }

    /// 没失败的一步在行尾写什么。改文件的规模随调用就有；搜索与读文件要等结果（`text` 为 nil 即还没有）。
    /// 按后端算好的规范形态、再按入参形状判，不查工具名表；命令与认不出的工具只有原文，不写。
    private static func result(of use: ToolUse, text: String?) -> StepResult? {
        if use.canonical?.kind == Canonical.Kind.fileEdit {
            let files = use.canonical?.editedFiles ?? []
            return .changed(plus: files.reduce(0) { $0 + $1.plus }, minus: files.reduce(0) { $0 + $1.minus })
        }
        if let lines = use.canonical?.writtenLines { return .changed(plus: lines, minus: 0) }
        guard use.category == .read, let input = use.input, let text else { return nil }
        if use.isSearch {
            return .matches(text.split(whereSeparator: \.isNewline).count { !$0.allSatisfy(\.isWhitespace) })
        }
        guard ToolUse.hasAnyKey(input, pathKeys) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .lines(trimmed.isEmpty ? 0 : trimmed.utf8.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 })
    }

    /// 三档视觉权重：思考与只读探查同为「不改变工程」，取最轻一档；出组档兜底按中性。
    public var weight: ActivityWeight {
        guard case .tool(_, let use, _) = self else { return .read }
        switch use.tier {
        case .read: return .read
        case .write: return .write
        case .neutral, .out: return .neutral
        }
    }

    /// 行首标签。shell 形态（入参里有 command）统一叫 Bash。
    public func label(cwd: String? = nil) -> StepLabel {
        guard case .tool(_, let use, _) = self else { return StepLabel(name: "", summary: "") }
        let name = use.input?["command"]?.string != nil ? "Bash" : ToolUse.displayName(use.name)
        if use.canonical?.kind == Canonical.Kind.fileEdit {
            let files = use.canonical?.editedFiles ?? []
            if files.count == 1 { return StepLabel(name: name, summary: relativizePath(files[0].path, cwd: cwd)) }
            if files.count > 1 { return StepLabel(name: name, summary: "", fileCount: files.count) }
        }
        let summary = summarizeInput(use.input, cwd: cwd)
        return StepLabel(name: name, summary: String(summary.prefix(Self.summaryMaxCharacters)))
    }
}

extension ToolUse {
    /// 只读档里的搜索形状（入参带 pattern / query）：结果按「N 处」报，图标是搜索。不查工具名表。
    public var isSearch: Bool {
        category == .read && input.map { Self.hasAnyKey($0, patternKeys) } ?? false
    }
}

// MARK: 入参摘要（移植自宿主 canonical-tool/raw/summary.ts，同样不查工具名）

private let pathKeys = ["path", "file_path", "file", "filename"]
private let patternKeys = ["pattern", "query"]

func summarizeInput(_ input: [String: JSONValue]?, cwd: String?) -> String {
    guard let input else { return "" }
    if let command = pickString(input, ToolUse.commandKeys) { return formatCommand(command) }
    if let path = pickString(input, pathKeys) { return relativizePath(path, cwd: cwd) }
    if let pattern = pickString(input, patternKeys) { return pattern }
    for key in input.keys.sorted() {
        guard let value = input[key], !value.isNull, value != .string("") else { continue }
        let text = value.string.map(collapseWhitespace) ?? value.compactText
        return "\(key)=\(text)"
    }
    return ""
}

private func pickString(_ input: [String: JSONValue], _ keys: [String]) -> String? {
    for key in keys {
        if let value = input[key]?.string, !value.isEmpty { return value }
    }
    return nil
}

private func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// 去掉 `zsh -lc '…'` 这一层外壳，只留真正的命令。
func formatCommand(_ command: String) -> String {
    let normalized = collapseWhitespace(command)
    guard let match = normalized.wholeMatch(of: /^(?:\/[^\s]+\/)?(?:zsh|bash|sh)\s+-lc\s+(['"])([\s\S]*)\1$/) else { return normalized }
    let quote = String(match.output.1)
    return String(match.output.2).replacingOccurrences(of: "\\" + quote, with: quote).trimmingCharacters(in: .whitespaces)
}

/// 工作目录之下的路径写成 `./相对路径`。
func relativizePath(_ path: String, cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return path }
    var trimmed = cwd
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    if path == trimmed { return "./" }
    if path.hasPrefix(trimmed + "/") { return "./" + path.dropFirst(trimmed.count + 1) }
    return path
}
