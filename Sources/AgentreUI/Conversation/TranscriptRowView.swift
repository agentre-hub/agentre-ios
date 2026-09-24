import AgentreDesign
import AgentreDomain
import SwiftUI

/// 转录的一行。
struct TranscriptRowView<Card: View>: View {
    let row: TranscriptRow
    let agentName: String
    let model: TranscriptModel
    let card: (TranscriptCard) -> Card

    var body: some View {
        switch row.content {
        case .user(let text):
            UserBubble(text: text)
        case .agentHeader:
            AgentSignature(name: agentName)
        case .text(let text, _):
            AgentText(segment: TextSegment(text: text, first: true, last: true))
        case .thinking(let text):
            Text(verbatim: text)
                .font(.subheadline.italic())
                .foregroundStyle(.token(.textSecondary))
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
                .font(.footnote)
                .foregroundStyle(.token(.failure))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }
}

/// 用户消息：右侧气泡。
private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(verbatim: text)
                .font(.body)
                .foregroundStyle(.token(.textPrimary))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.token(.surface2), in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(.vertical, 8)
    }
}

/// 助手消息的首行：头像与署名。
private struct AgentSignature: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.caption.weight(.bold))
                .foregroundStyle(.token(.onAccent))
                .frame(width: 24, height: 24)
                .background(.token(.accent), in: Circle())
                .accessibilityHidden(true)
            Text(verbatim: name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.token(.textPrimary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// agent 的正文：全宽、无气泡。行内 Markdown 按原样解析，解析不了就逐字呈现。
/// 极长的正文切成几格（`TranscriptCells`）逐格呈现：上下留白只加在整段两端，格子之间补回两行之间本有的
/// 行距，读起来仍是一整段。按段落比较：一片增量只让最末那一格重排，前面的格子不重算。
struct AgentText: View, Equatable {
    let segment: TextSegment
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let attributed = try? AttributedString(markdown: segment.text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(verbatim: segment.text)
            }
        }
        .font(.body)
        .foregroundStyle(.token(.textPrimary))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, segment.first ? 4 : lineGap)
        .padding(.bottom, segment.last ? 4 : 0)
    }

    /// 同一段文字里上一行与下一行之间的行距（按像素向下取整，与文字排版的取整一致）；分在两格里时它不在任何一格之内。
    private var lineGap: CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        let leading = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).leading
        return (leading * displayScale).rounded(.down) / displayScale
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.segment == rhs.segment }
}
