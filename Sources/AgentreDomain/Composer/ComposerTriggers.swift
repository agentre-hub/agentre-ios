import Foundation

// 就地触发的判定，移植自宿主 agentre-ui/src/chat-input/slash/trigger.ts 与 mentions/trigger.ts；
// 候选评分移植自 agentre-ui/src/lib/suggestion-score.ts。偏移以 Character 计。

public struct SlashTriggerHit: Sendable, Equatable {
    /// 触发字符在光标前文本里的偏移。
    public var startOffset: Int
    /// 触发字符之后到光标的文本。
    public var query: String
    public var trigger: Character

    public init(startOffset: Int, query: String, trigger: Character) {
        self.startOffset = startOffset
        self.query = query
        self.trigger = trigger
    }
}

public struct MentionTriggerHit: Sendable, Equatable {
    public var startOffset: Int
    public var query: String

    public init(startOffset: Int, query: String) {
        self.startOffset = startOffset
        self.query = query
    }
}

public enum ComposerTrigger {
    /// 触发字符左侧紧邻行首或空白才算（`foo/bar` 不触发）；query 里出现空白即视为已结束。
    public static func detectSlash(_ textBeforeCursor: String, triggers: Set<Character>) -> SlashTriggerHit? {
        guard let (offset, query, trigger) = detect(textBeforeCursor, triggers: triggers) else { return nil }
        return SlashTriggerHit(startOffset: offset, query: query, trigger: trigger)
    }

    /// 同一条规矩：`a@b.com` 不触发。
    public static func detectMention(_ textBeforeCursor: String) -> MentionTriggerHit? {
        guard let (offset, query, _) = detect(textBeforeCursor, triggers: ["@"]) else { return nil }
        return MentionTriggerHit(startOffset: offset, query: query)
    }

    private static func detect(_ text: String, triggers: Set<Character>) -> (Int, String, Character)? {
        let characters = Array(text)
        var index = characters.count - 1
        while index >= 0 {
            let character = characters[index]
            if triggers.contains(character) {
                guard index == 0 || characters[index - 1].isWhitespace else { return nil }
                return (index, String(characters[(index + 1)...]), character)
            }
            if character.isWhitespace { return nil }
            index -= 1
        }
        return nil
    }
}

/// 候选评分阶梯（先命中先得，不叠加）：全等 100、前缀 80、包含 60；query 全 ASCII 时
/// 拼音全拼包含 50、首字母包含 40、按序出现在全拼里 30；副标题包含 20；不命中 0；空 query 1。
public enum SuggestionScore {
    public static func score(query: String, title: String, subtitle: String? = nil) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 1 }
        let needle = trimmed.lowercased()
        let hay = title.lowercased()
        if needle == hay { return 100 }
        if hay.hasPrefix(needle) { return 80 }
        if hay.contains(needle) { return 60 }
        if needle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            let (full, initials) = pinyin(title)
            if full.contains(needle) { return 50 }
            if initials.contains(needle) { return 40 }
            if inOrder(needle, in: full) { return 30 }
        }
        if let subtitle, subtitle.lowercased().contains(needle) { return 20 }
        return 0
    }

    /// 逐字转写：汉字取无声调拼音，其余字符原样（与宿主 pinyin-pro 对非汉字的处理一致）。
    private static func pinyin(_ title: String) -> (full: String, initials: String) {
        var full = ""
        var initials = ""
        for character in title {
            let latin = String(character).applyingTransform(.mandarinToLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)?
                .replacingOccurrences(of: " ", with: "")
                .lowercased() ?? String(character).lowercased()
            full += latin
            if let first = latin.first { initials.append(first) }
        }
        return (full, initials)
    }

    private static func inOrder(_ needle: String, in hay: String) -> Bool {
        var remaining = needle[...]
        for character in hay where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return false
    }
}
