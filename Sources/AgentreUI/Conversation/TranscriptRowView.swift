import AgentreDesign
import AgentreDomain
import SwiftUI

/// 助手一侧的正文、活动块与卡片都排在头像右边这一列（稿子：30pt 头像 + 9pt 间距）。
let replyIndent: CGFloat = 39

/// 转录的一行。
struct TranscriptRowView<Card: View>: View {
    let row: TranscriptRow
    let agentName: String
    let model: TranscriptModel
    let card: (TranscriptCard) -> Card

    var body: some View {
        switch row.content {
        case .day(let time):
            DayCapsule(time: time)
        case .user(let text):
            UserBubble(text: text)
        case .agentHeader(let model):
            AgentSignature(name: agentName, model: model)
        default:
            reply.padding(.leading, replyIndent)
        }
    }

    @ViewBuilder private var reply: some View {
        switch row.content {
        case .text(let text, _):
            AgentText(segment: TextSegment(text: text, first: true, last: true))
        case .thinking(let text):
            Text(verbatim: text)
                .font(.agentre(.subheadline))
                .italic()
                .foregroundStyle(.token(.ink2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        case .activityHeader(let header):
            ActivityHeaderView(header: header) { model.toggle(header.blockKey, current: header.expanded) }
        case .step(let step):
            ActivityStepView(step: step) { model.toggle(step.key, current: step.expanded) }
        case .stepDetail(let step):
            ActivityStepDetailView(step: step)
        case .elided(let elided):
            ElidedStepsView(elided: elided) { model.showAll(elided.blockKey) }
        case .subagent(let subagent):
            SubagentLineView(subagent: subagent) { model.toggle(subagent.key, current: subagent.expanded) }
        case .card(let value):
            card(value)
        case .error(let text):
            Group {
                if text.isEmpty {
                    Text("transcript.error.unknown", tableName: "Conversation", bundle: .module)
                } else {
                    Text(verbatim: text)
                }
            }
                .font(.agentre(.footnote))
                .foregroundStyle(.token(.coral))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        case .day, .user, .agentHeader:
            EmptyView()
        }
    }
}

/// 日期胶囊：`surface` 底，写「今天 9:32」「昨天 9:32」或日期加时刻。
private struct DayCapsule: View {
    let time: Int64
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        let date = Date(timeIntervalSince1970: TimeInterval(time) / 1000)
        let clock = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar))
        Group {
            switch CapsuleDay.of(date, now: .now, calendar: calendar) {
            case .today: Text("transcript.day.today \(clock)", tableName: "Conversation", bundle: .module)
            case .yesterday: Text("transcript.day.yesterday \(clock)", tableName: "Conversation", bundle: .module)
            case .earlier: Text(verbatim: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar)))
            }
        }
        .font(.agentre(FontRole(size: 11, relativeTo: .caption2)))
        .foregroundStyle(.token(.ink3))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minHeight: 22)
        .background(.token(.surface), in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }
}

/// 用户消息：`primary` 底、`primary-ink` 字的右侧气泡，右下角收尖。草稿发出的第一条也画成这一枚。
struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(verbatim: text)
                .font(.agentre(FontRole(size: 14.5, relativeTo: .body)))
                .lineSpacing(5)
                .foregroundStyle(.token(.primaryInk))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.token(.primary), in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18))
                .frame(maxWidth: 290, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

/// 助手消息的首行：`surface-2` 圆形头像里一枚 `primary` 图标；署名是后端的显示名，后接等宽的模型名。
private struct AgentSignature: View {
    let name: String
    let model: String?

    var body: some View {
        HStack(spacing: 9) {
            Image(.sparkles)
                .resizable()
                .frame(width: 15, height: 15)
                .foregroundStyle(.token(.primary))
                .frame(width: 30, height: 30)
                .background(.token(.surface2), in: Circle())
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text(verbatim: name)
                    .font(.agentre(.footnote, weight: .semibold))
                    .foregroundStyle(.token(.ink2))
                if let model {
                    Text(verbatim: model)
                        .font(.agentre(.caption2, mono: true))
                        .foregroundStyle(.token(.ink3))
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 7)
        .accessibilityElement(children: .combine)
    }
}

/// agent 的正文：全宽、无气泡。行内 Markdown 按原样解析，解析不了就逐字呈现。
/// 极长的正文切成几格（`TranscriptCells`）逐格呈现：上下留白只加在整段两端，格子之间补回两行之间本有的
/// 行距，读起来仍是一整段。按段落比较：一片增量只让最末那一格重排，前面的格子不重算。
struct AgentText: View, Equatable {
    let segment: TextSegment
    /// 正文切成了几格时读出整段正文：长按任一格拷贝的是整条回复，而不是看不出边界的一截。
    /// 拷贝时才读，不参与比较。
    var copyReply: (() -> String?)?
    /// 拷贝写进的剪贴板（测试换成进程内的具名剪贴板：测试进程读不了系统剪贴板）。
    @MainActor static var pasteboard = UIPasteboard.general
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Text(Self.rendered(segment.text))
            .font(.agentre(Self.role))
            .lineSpacing(lineSpacing)
            .foregroundStyle(.token(.ink))
            .modifier(ReplyCopy(copyReply: copyReply))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, segment.first ? 4 : lineGap)
            .padding(.bottom, segment.last ? 4 : 0)
    }

    /// 行内 Markdown 按原样解析，解析不了就逐字呈现。
    static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// 正文字号：稿子 14.5pt、行高 1.55。
    static let role = FontRole(size: 14.5, relativeTo: .body)

    private var font: UIFont {
        UIFont.agentre(Self.role, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize)))
    }

    /// 行高撑到 1.55 倍字号多出来的行间距。
    private var lineSpacing: CGFloat {
        max(0, font.pointSize * 1.55 - font.lineHeight)
    }

    /// 同一段文字里上一行与下一行之间的行距（按像素向下取整，与文字排版的取整一致）；分在两格里时它不在任何一格之内。
    private var lineGap: CGFloat {
        ((font.leading + lineSpacing) * displayScale).rounded(.down) / displayScale
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.segment == rhs.segment }
}

/// 整段在一格里：选中文字即整条回复。切成了几格：长按（及读屏的动作）拷贝整条回复。
private struct ReplyCopy: ViewModifier {
    let copyReply: (() -> String?)?

    func body(content: Content) -> some View {
        if let copyReply {
            let copy = { if let reply = copyReply() { AgentText.pasteboard.string = reply } }
            content
                .contextMenu {
                    Button(action: copy) {
                        Label { Text("transcript.copyReply", tableName: "Conversation", bundle: .module) } icon: { Image(systemName: "doc.on.doc") }
                    }
                }
                .accessibilityAction(named: Text("transcript.copyReply", tableName: "Conversation", bundle: .module), copy)
        } else {
            content.textSelection(.enabled)
        }
    }
}
