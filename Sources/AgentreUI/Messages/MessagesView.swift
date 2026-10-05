import AgentreDesign
import AgentreDomain
import SwiftUI

/// 消息列表：应用主屏，读本地库。头部（标题与新建入口）由宿主经 `.topLevelHeader` 接上；
/// 其下是本地搜索——按标题 / 项目名 / 机器名做大小写不敏感的子串匹配，不发网络请求。
/// 等你处理的行置顶并铺 `surface` 底，行上直接给出待批准的命令或待回答的问题，行尾是尚未处理的
/// 请求条数；运行中的行读作「正在输入…」；未读以标题加粗加一枚圆点表达，不写条数（规格「01 消息」）。
public struct MessagesView: View {
    @Bindable private var model: MessagesModel
    private let onOpen: (ConversationKey) -> Void

    /// - Parameter onOpen: 进入一条对话。导航归宿主。
    public init(model: MessagesModel, onOpen: @escaping (ConversationKey) -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    public var body: some View {
        List {
            SearchField(text: $model.query, placeholder: "messages.search", table: "Messages")
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            let rows = model.conversations
            ForEach(rows) { conversation in
                VStack(spacing: 0) {
                    Button {
                        onOpen(conversation.key)
                        Task { await model.markRead(conversation.key) }
                    } label: {
                        MessageRow(conversation: conversation, glyph: model.glyph(for: conversation))
                    }
                    .hitTarget()
                    // 平铺行加分隔线，不做卡片：分隔线避开头像，与稿子的缩进对齐。
                    if conversation.id != rows.last?.id {
                        Rectangle().fill(.token(.line)).frame(height: 1).padding(.leading, MessageRow.dividerInset)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(conversation.activity == .waiting ? Color.token(.surface) : Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.token(.bg))
        .task {
            await model.load()
            await model.follow()
        }
    }
}

/// 一行：项目字形头像（右下角挂状态点）、标题、时间、未读点，下面一行是预览。
struct MessageRow: View {
    let conversation: SavedConversation
    let glyph: IdentityGlyph

    private var isWaiting: Bool { conversation.activity == .waiting }
    /// 头像（50）+ 左边距（18）+ 头像与正文的间距（12），分隔线与它对齐、避开头像。
    static let dividerInset: CGFloat = 18 + 50 + 12

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 0)
                    if conversation.lastMessageAt > 0 {
                        Text(Date(timeIntervalSince1970: TimeInterval(conversation.lastMessageAt) / 1000), format: .relative(presentation: .named))
                            .font(.agentre(.caption))
                            .foregroundStyle(.token(.ink2))
                    }
                    // 未读是有无，不是条数（决策 17/19）：一枚圆点，不写数字。
                    if conversation.isUnread {
                        Circle()
                            .fill(.token(.primary))
                            .frame(width: 8, height: 8)
                            .accessibilityLabel(Text("messages.unread", tableName: "Messages", bundle: .module))
                    }
                }
                preview
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            AvatarGlyph(glyph, size: 50)
            // 头像右下角的状态点：琥珀表等你处理，绿表运行中，其余不挂（规格「01 消息」）。
            if let token = conversation.activity.avatarBadgeToken {
                Circle()
                    .fill(.token(token))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.token(isWaiting ? .surface : .bg), lineWidth: 2.5))
                    .accessibilityLabel(Text(conversation.activity.avatarBadgeLabel!, tableName: "Messages", bundle: .module))
                    .offset(x: 2, y: 2)
            }
        }
    }

    @ViewBuilder private var title: some View {
        if conversation.title.isEmpty {
            // 没有标题时以会话 ID 认出：机器产出的内容用等宽字体。
            Text(verbatim: conversation.key.conversationID)
                .font(.agentre(.body, mono: true, weight: conversation.isUnread ? .semibold : .regular))
                .foregroundStyle(.token(.ink))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(verbatim: conversation.title)
                .font(.agentre(.body, weight: conversation.isUnread ? .semibold : .regular))
                .foregroundStyle(.token(.ink))
                .lineLimit(1)
        }
    }

    @ViewBuilder private var preview: some View {
        switch conversation.activity {
        case .waiting:
            pendingPreview
        case .typing:
            Text("messages.typing", tableName: "Messages", bundle: .module)
                .font(.agentre(.subheadline))
                .foregroundStyle(.token(.run))
        case .failed, .idle:
            if !conversation.lastText.isEmpty {
                Text(verbatim: conversation.lastText)
                    .font(.agentre(.subheadline))
                    .foregroundStyle(.token(.ink2))
                    .lineLimit(2)
            }
        }
    }

    /// 琥珀色的待处理事项，一行（命令与工具名等宽），行尾是这条会话里尚未处理的请求条数。
    @ViewBuilder private var pendingPreview: some View {
        switch conversation.pending {
        case .permission(let tool, let detail):
            pendingLine(icon: .shieldAlert) {
                // 种类与审批卡标题同一规则（`ApprovalInput`：Bash 突出 command）：命令类写出命令本身，其余写工具名。
                if tool == "Bash", let detail {
                    Text("messages.pending.command \(Text(verbatim: detail).font(.agentre(.subheadline, mono: true)))",
                         tableName: "Messages", bundle: .module)
                } else {
                    Text("messages.pending.tool \(Text(verbatim: tool).font(.agentre(.subheadline, mono: true)))",
                         tableName: "Messages", bundle: .module)
                }
            }
        case .question(let question):
            pendingLine(icon: .messageCircleQuestionMark) {
                Text(verbatim: question)
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func pendingLine(icon: AgentreIcon, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Image(icon)
                .resizable()
                .frame(width: 13, height: 13)
                .foregroundStyle(.token(.amber))
                .accessibilityHidden(true)
            content()
                .font(.agentre(.subheadline))
                .foregroundStyle(.token(.amber))
                .lineLimit(1)
            if conversation.pendingCount > 0 {
                Spacer(minLength: 8)
                Text(verbatim: "\(conversation.pendingCount)")
                    .font(.agentre(.footnote, weight: .semibold))
                    .foregroundStyle(.token(.amberDim))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 19, minHeight: 19)
                    .background(.token(.amber), in: Capsule())
                    .accessibilityLabel(Text("messages.pendingCount \(conversation.pendingCount)", tableName: "Messages", bundle: .module))
            }
        }
    }
}

extension ConversationActivity {
    /// 状态的图标、颜色与读屏名；闲着时为 nil（机器详情行首的状态标记据此画，见 `MachineSessionStatusDot`）。
    var statusPresentation: (symbol: String, token: ColorToken, label: LocalizedStringKey)? {
        switch self {
        case .waiting: ("hand.raised.fill", .amber, "messages.status.waiting")
        case .typing: ("ellipsis.circle.fill", .run, "messages.status.running")
        case .failed: ("exclamationmark.triangle.fill", .coral, "messages.status.failed")
        case .idle: nil
        }
    }

    /// 头像角标的颜色：琥珀表等你处理，绿表运行中，其余不挂（规格「01 消息」）。
    var avatarBadgeToken: ColorToken? {
        switch self {
        case .waiting: .amber
        case .typing: .run
        case .failed, .idle: nil
        }
    }

    /// 头像角标的读屏名；没有角标时为 nil。
    var avatarBadgeLabel: LocalizedStringKey? {
        switch self {
        case .waiting: "messages.status.waiting"
        case .typing: "messages.status.running"
        case .failed, .idle: nil
        }
    }
}
