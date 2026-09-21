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
            AgentText(text: text)
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
            Text(verbatim: text)
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
private struct AgentText: View {
    let text: String

    var body: some View {
        Group {
            if let attributed = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(verbatim: text)
            }
        }
        .font(.body)
        .foregroundStyle(.token(.textPrimary))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
