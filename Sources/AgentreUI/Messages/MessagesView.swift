import AgentreDesign
import AgentreDomain
import SwiftUI

/// 消息列表：应用主屏，读本地库。等你处理的置顶并抬高，行上直接给出待批准的命令或
/// 待回答的问题；运行中的行读作「正在输入…」；未读以一个点表达。
public struct MessagesView: View {
    private let model: MessagesModel
    private let onOpen: (ConversationKey) -> Void

    /// - Parameter onOpen: 进入一条对话。导航归宿主。
    public init(model: MessagesModel, onOpen: @escaping (ConversationKey) -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    public var body: some View {
        List(model.conversations) { conversation in
            Button {
                onOpen(conversation.key)
                Task { await model.markRead(conversation.key) }
            } label: {
                MessageRow(conversation: conversation)
            }
            .hitTarget()
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.token(.bg))
        .localizedNavigationTitle("messages.title", table: "Messages")
        .task {
            await model.load()
            await model.follow()
        }
    }
}

/// 一行：状态点、标题、时间、未读点，下面一行是预览。
struct MessageRow: View {
    let conversation: SavedConversation

    private var isWaiting: Bool { conversation.activity == .waiting }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ConversationStatusGlyph(activity: conversation.activity)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 0)
                    if conversation.lastMessageAt > 0 {
                        Text(Date(timeIntervalSince1970: TimeInterval(conversation.lastMessageAt) / 1000), format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.token(.textSecondary))
                    }
                    if conversation.isUnread {
                        Circle()
                            .fill(.token(.accent))
                            .frame(width: 8, height: 8)
                            .accessibilityLabel(Text("messages.unread", tableName: "Messages", bundle: .module))
                    }
                }
                preview
            }
        }
        .padding(isWaiting ? 16 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.token(isWaiting ? .surface2 : .surface), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if isWaiting {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.token(.waiting), lineWidth: 1.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var title: some View {
        if conversation.title.isEmpty {
            // 没有标题时以会话 ID 认出：机器产出的内容用等宽字体。
            Text(verbatim: conversation.key.conversationID)
                .font(.body.monospaced().weight(isWaiting ? .semibold : .regular))
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(verbatim: conversation.title)
                .font(isWaiting ? .headline : .body)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(1)
        }
    }

    @ViewBuilder private var preview: some View {
        switch conversation.activity {
        case .waiting:
            pendingPreview
        case .typing:
            Text("messages.typing", tableName: "Messages", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.token(.running))
        case .failed, .idle:
            if !conversation.lastText.isEmpty {
                Text(verbatim: conversation.lastText)
                    .font(.subheadline)
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder private var pendingPreview: some View {
        switch conversation.pending {
        case .permission(let tool, let detail):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: tool)
                    .font(.caption.monospaced())
                    .foregroundStyle(.token(.waiting))
                if let detail {
                    Text(verbatim: detail)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.token(.textPrimary))
                        .lineLimit(3)
                }
            }
        case .question(let question):
            Text(verbatim: question)
                .font(.subheadline)
                .foregroundStyle(.token(.textPrimary))
                .lineLimit(3)
        case nil:
            EmptyView()
        }
    }
}

/// 会话的状态：颜色之外还有一枚各不相同的图标，读屏读出状态名——状态不只靠颜色区分。
/// 闲着的会话不画，只留出位置。消息列表与机器详情是同一套。
struct ConversationStatusGlyph: View {
    let activity: ConversationActivity

    var body: some View {
        Group {
            if let presentation = activity.statusPresentation {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(.token(presentation.token))
                    .accessibilityLabel(Text(presentation.label, tableName: "Messages", bundle: .module))
            } else {
                // 同一字号下一枚图标的宽度，不多占：Color.clear 会吃掉 HStack 分出来的富余宽度，
                // 与标题对半分行宽，把标题挤到行中右。
                Image(systemName: "circle")
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .frame(minWidth: 14, minHeight: 14)
    }
}

extension ConversationActivity {
    /// 状态的图标、颜色与读屏名；闲着时为 nil。
    var statusPresentation: (symbol: String, token: ColorToken, label: LocalizedStringKey)? {
        switch self {
        case .waiting: ("hand.raised.fill", .waiting, "messages.status.waiting")
        case .typing: ("ellipsis.circle.fill", .running, "messages.status.running")
        case .failed: ("exclamationmark.triangle.fill", .failure, "messages.status.failed")
        case .idle: nil
        }
    }
}
