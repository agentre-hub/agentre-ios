import Foundation

// 提及的候选与正文序列化，规则移植自宿主 agentre-ui/src/chat-input/mentions/ 的 xml.ts 与
// rank-items.ts；来路对齐控制台 agentre-server/frontend/src/components/session/SessionComposer.tsx
// （`buildMentionSources(agents, [], devices)`：Agent 与账号设备，项目不摆）。

public struct ComposerMentionAgent: Sendable, Equatable {
    public var id: Int64
    public var name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ComposerMentionDevice: Sendable, Equatable {
    /// 设备提及在正文里的唯一身份：消息被别的机器读到时只有指纹还指得回同一台。
    public var fingerprint: String
    public var name: String
    public var online: Bool

    public init(fingerprint: String, name: String, online: Bool) {
        self.fingerprint = fingerprint
        self.name = name
        self.online = online
    }
}

public struct ComposerMentionSources: Sendable, Equatable {
    public var agents: [ComposerMentionAgent]
    public var devices: [ComposerMentionDevice]

    public init(agents: [ComposerMentionAgent] = [], devices: [ComposerMentionDevice] = []) {
        self.agents = agents
        self.devices = devices
    }
}

public enum MentionRef: Sendable, Equatable, Hashable {
    case agent(id: Int64, name: String)
    case device(fingerprint: String, name: String)

    public var label: String {
        switch self {
        case .agent(_, let name), .device(_, let name): name
        }
    }

    /// 写进正文的形态：`<agent id="N">名字</agent>` / `<device fp="…">名字</device>`。
    public var xml: String {
        switch self {
        case .agent(let id, let name): "<agent id=\"\(id)\">\(Self.escape(name))</agent>"
        case .device(let fingerprint, let name): "<device fp=\"\(Self.escape(fingerprint))\">\(Self.escape(name))</device>"
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public struct MentionCandidate: Sendable, Equatable {
    public var ref: MentionRef
    /// 设备的在线态；Agent 为 nil。
    public var online: Bool?

    public init(ref: MentionRef, online: Bool? = nil) {
        self.ref = ref
        self.online = online
    }

    public var label: String { ref.label }
}

public enum ComposerMentions {
    /// Agent 一组、设备一组，组内按评分排序（同分维持源顺序）；没有指纹的设备整条不列。
    public static func rank(_ sources: ComposerMentionSources, query: String) -> [MentionCandidate] {
        let agents = sources.agents.map { MentionCandidate(ref: .agent(id: $0.id, name: $0.name)) }
        let devices = sources.devices.filter { !$0.fingerprint.isEmpty }
            .map { MentionCandidate(ref: .device(fingerprint: $0.fingerprint, name: $0.name), online: $0.online) }
        return rankGroup(agents, query) + rankGroup(devices, query)
    }

    /// 发送时把正文里的 `@名字` 换成提及 XML：每个选过的提及换第一处完整的 `@名字`，用户删掉了的不换。
    /// 完整 = 前面是开头或空白（与键入 `@` 触发候选同一条件），后面是结尾、空白或标点：
    /// 选过 `Al` 时不能改写 `@Alice` 里的前缀。名字为空的提及不换。
    public static func serialize(_ text: String, mentions: [MentionRef]) -> String {
        // 换过的那处已成 XML、不再以 `@名字` 出现，所以每次从头找到的就是下一处。
        mentions.reduce(text) { result, ref in
            guard !ref.label.isEmpty, let range = standaloneRange(of: "@\(ref.label)", in: result) else { return result }
            return result.replacingCharacters(in: range, with: ref.xml)
        }
    }

    private static func standaloneRange(of needle: String, in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            let startsClean = range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)].isWhitespace
            let endsClean = range.upperBound == text.endIndex
                || text[range.upperBound].isWhitespace || text[range.upperBound].isPunctuation
            if startsClean && endsClean { return range }
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func rankGroup(_ items: [MentionCandidate], _ query: String) -> [MentionCandidate] {
        let scored: [(item: MentionCandidate, index: Int, score: Int)] = items.enumerated().map { index, item in
            (item, index, SuggestionScore.score(query: query, title: item.label))
        }
        return scored
            .filter { $0.score > 0 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.item)
    }
}

extension ComposerMentions {
    /// 正文里的提及 XML 还原成可读的 `@名字`，给只呈现纯文本的地方（排队条与「未发送」）。
    public static func displayText(_ text: String) -> String {
        draft(fromBody: text).text
    }

    /// `serialize` 的逆：发出去的正文还回输入框时，提及 XML 还原成 `@名字`，并交回它们各自的提及
    /// （再发送时照样换回 XML，而不是丢成一段纯文本）。
    public static func draft(fromBody body: String) -> (text: String, mentions: [MentionRef]) {
        var mentions: [MentionRef] = []
        let text = body.replacing(/<(agent|device)\b([^>]*)>(.*?)<\/\1>/) { match in
            let name = unescape(String(match.output.3))
            let attributes = String(match.output.2)
            if match.output.1 == "agent", let id = attribute("id", in: attributes).flatMap({ Int64($0) }) {
                mentions.append(.agent(id: id, name: name))
            } else if match.output.1 == "device", let fingerprint = attribute("fp", in: attributes) {
                mentions.append(.device(fingerprint: unescape(fingerprint), name: name))
            }
            return "@\(name)"
        }
        return (text, mentions)
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let range = attributes.range(of: "\(name)=\""),
              let end = attributes[range.upperBound...].firstIndex(of: "\"")
        else { return nil }
        return String(attributes[range.upperBound..<end])
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
