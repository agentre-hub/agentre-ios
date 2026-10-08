import Foundation

/// 审批卡片上的那一块机器文本：执行目录、完整输入，以及过长时代替它的摘要。
/// 只看工具名与原始输入的形状排版，不对内容做任何判断。
public struct ApprovalInput: Sendable, Equatable {
    /// 超过这么多行或这么多字符即算过长。
    static let maximumLines = 6
    static let maximumCharacters = 320
    /// 摘要的长度上限（宿主 formatToolSummary 同值）。
    static let summaryLimit = 100

    public let toolName: String
    /// 执行目录；不知道时为空。
    public let cwd: String
    /// 按终端排的命令（Bash 的 command）；别的工具为 nil。
    public let command: String?
    /// 完整输入：命令本身，或键按字典序、两格缩进的 JSON；没有输入时为空。
    public let text: String
    /// 一行摘要：命令或压成一行的 JSON，只取首行，超长截断。
    public let summary: String

    public init(toolName: String, input: [String: JSONValue]?, cwd: String) {
        self.toolName = toolName
        self.cwd = cwd
        guard let input else {
            command = nil
            text = ""
            summary = ""
            return
        }
        // 与宿主同一规则：Bash 突出 command，其余工具退回 JSON。
        let command = toolName == "Bash" ? input["command"]?.string : nil
        self.command = command
        text = command ?? Self.indented(.object(input), depth: 0)
        let line = (command ?? JSONValue.object(input).compactText)
            .split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? ""
        summary = line.count > Self.summaryLimit ? String(line.prefix(Self.summaryLimit - 3)) + "..." : line
    }

    /// 过长：卡片先给摘要，展开才见全文。
    public var isLong: Bool {
        text.count > Self.maximumCharacters || text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count > Self.maximumLines
    }

    /// 键按字典序、两格缩进的 JSON（与 JSON.stringify(value, null, 2) 同形）。
    private static func indented(_ value: JSONValue, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth + 1)
        let close = String(repeating: "  ", count: depth)
        switch value {
        case .object(let fields) where !fields.isEmpty:
            let lines = fields.keys.sorted().map { key in
                "\(pad)\(JSONValue.string(key).compactText): \(indented(fields[key]!, depth: depth + 1))"
            }
            return "{\n\(lines.joined(separator: ",\n"))\n\(close)}"
        case .array(let items) where !items.isEmpty:
            let lines = items.map { "\(pad)\(indented($0, depth: depth + 1))" }
            return "[\n\(lines.joined(separator: ",\n"))\n\(close)]"
        default:
            return value.compactText
        }
    }
}
