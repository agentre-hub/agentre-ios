import Foundation

/// 项目或 Agent 的身份色（服务端的 `agent-1`…`agent-16` 词汇表，`agentre-ui/lib/agent-color.ts`
/// 同一套）。缺失、空串、越界或裸色值（如 `#3B6896`）一律中性——中性不是「没有颜色」的占位，
/// 是画不出身份色时唯一的兜底（规格「全局框架」头像字形一条：颜色只表状态不作装饰，
/// 唯一的例外是这一份，且只出现在头像字形上）。
public enum IdentityColor: Sendable, Equatable {
    case slot(Int)
    case neutral

    /// - Parameter wireToken: 服务端下发的原始 token（项目的 `color`、Agent 的 `avatar_color`）。
    public init(wireToken: String?) {
        guard let token = wireToken, let n = Self.slotNumber(in: token) else {
            self = .neutral
            return
        }
        self = .slot(n)
    }

    private static func slotNumber(in token: String) -> Int? {
        guard token.hasPrefix("agent-") else { return nil }
        guard let n = Int(token.dropFirst("agent-".count)), (1...16).contains(n) else { return nil }
        return n
    }
}

/// 项目名首字，原样大小写；空名（或纯空白）不编一个字母出来（宿主 `initialOf`）。
public func projectInitial(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return nil }
    return String(first)
}

/// Agent 首字母（宿主 `getAgentInitials`）：两个拉丁/数字开头的词取各自首字母大写
/// （`Code Reviewer` → `CR`；`CEO 助手` 因第二个词不是拉丁/数字开头不拼，取首字 `C`）；
/// 其余取首字大写。**与宿主不同**：名字为空（或纯空白）这里不编一个字母出来，宿主的 `?`
/// 是给可及名兜底的，这里不需要。
public func agentInitial(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let words = trimmed.split(whereSeparator: \.isWhitespace)
    let pair = Array(words.prefix(2))
    if pair.count > 1, pair.allSatisfy(startsWithLatinOrDigit) {
        return pair.map { String($0.prefix(1)).uppercased() }.joined()
    }
    return String(trimmed.prefix(1)).uppercased()
}

/// `/^[a-z0-9]/i` 的移植：第一个字符是不是 ASCII 字母或数字。
private func startsWithLatinOrDigit(_ word: Substring) -> Bool {
    guard let scalar = word.unicodeScalars.first?.value else { return false }
    return (0x30...0x39).contains(scalar) || (0x41...0x5A).contains(scalar) || (0x61...0x7A).contains(scalar)
}

/// 头像字形该画什么：项目/Agent 的身份色加首字，不属于任何项目的中性字形，或项目已挂但
/// 项目树还没取到时的空白字形（规格「全局框架」头像字形一条）。
public enum IdentityGlyph: Sendable, Equatable {
    /// 项目或 Agent 解出来了：它的身份色，字母为 nil 即名字为空。
    case identity(letter: String?, color: IdentityColor)
    /// 不属于任何项目。
    case neutral
    /// 项目已挂，但项目树一次都还没取到——此刻不知道，不能当作「不属于任何项目」。
    case blank

    /// 会话挂的项目字形。
    /// - Parameters:
    ///   - syncID: 会话记的 `project_sync_id`；空串即没挂项目。
    ///   - projects: 账号的项目树；`nil` 表示一次都没成功取到过。
    public static func project(_ syncID: String, in projects: [WorkspaceProject]?) -> IdentityGlyph {
        guard !syncID.isEmpty else { return .neutral }
        guard let projects else { return .blank }
        guard let project = projects.first(where: { $0.syncID == syncID }) else { return .neutral }
        return .identity(letter: projectInitial(project.name), color: project.color)
    }

    /// Agent 字形：Agent 的名字与身份色随清单一起下发，不需要「还没取到」这一档。
    public static func agent(_ agent: WorkspaceAgent) -> IdentityGlyph {
        .identity(letter: agentInitial(agent.name), color: agent.avatarColor)
    }
}
