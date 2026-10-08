import Foundation

// 一步工具调用落在哪一档视觉权重的纯判据，移植自宿主 agentre-ui 的 canonical-tool/tier.ts。
// 按顺序取第一个命中：① canonical.kind（后端已算好）② 入参形状 ③ 都不匹配落中性档。
// **不查工具名表** —— 那是后端专有知识的泄漏。认不出来的工具落中性档，不假装它是只读。

extension ToolUse {
    private static let outKinds: Set<String> = [
        Canonical.Kind.agentSpawn, Canonical.Kind.userAsk, Canonical.Kind.planApproveRequest, Canonical.Kind.toolPermission,
    ]
    private static let writeKinds: Set<String> = [Canonical.Kind.fileWrite, Canonical.Kind.fileEdit]

    static let commandKeys = ["command", "cmd"]
    private static let writeShapeKeys = ["content", "edits", "old_string"]
    // 定位语义字段与摘要的探测同源；写入语义字段先判，所以 Write 的 {file_path, content} 仍是写层。
    private static let readShapeKeys = ["path", "file_path", "file", "filename", "pattern", "query", "url"]

    public var tier: ToolTier {
        if let kind = canonical?.kind {
            if Self.outKinds.contains(kind) { return .out }
            if Self.writeKinds.contains(kind) { return .write }
        }
        if let input {
            if Self.hasAnyKey(input, Self.commandKeys) { return .write }
            if Self.hasAnyKey(input, Self.writeShapeKeys) { return .write }
            if Self.hasAnyKey(input, Self.readShapeKeys) { return .read }
        }
        return .neutral
    }

    /// 比 tier 细一档：写层内部再分「改文件 / 写入 / 命令」。档位仍由 tier 独家判定。
    public var category: ToolCategory {
        let tier = tier
        if tier == .out { return .other }
        if canonical?.kind == Canonical.Kind.fileEdit { return .edit }
        if canonical?.kind == Canonical.Kind.fileWrite { return .write }
        if tier == .write, let input, Self.hasAnyKey(input, Self.commandKeys) { return .command }
        if tier == .write { return .write }
        return tier == .read ? .read : .other
    }

    /// `mcp__<server>__<tool>` 拆成「server · tool」，其余原样。
    public static func displayName(_ name: String) -> String {
        let prefix = "mcp__"
        guard name.hasPrefix(prefix) else { return name }
        let rest = name.dropFirst(prefix.count)
        guard let separator = rest.range(of: "__") else { return name }
        let server = rest[..<separator.lowerBound]
        let tool = rest[separator.upperBound...]
        guard !server.isEmpty, !tool.isEmpty else { return name }
        return "\(server) · \(tool)"
    }

    /// 宿主的 hasAnyKey 判 `input[k] != null`：缺键与 null 都不算命中。
    static func hasAnyKey(_ input: [String: JSONValue], _ keys: [String]) -> Bool {
        keys.contains { key in input[key].map { !$0.isNull } ?? false }
    }
}
