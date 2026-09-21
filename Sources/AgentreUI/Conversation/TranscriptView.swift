import AgentreDesign
import AgentreDomain
import SwiftUI

/// 对话屏的转录。用户消息是右侧气泡；agent 回复全宽无气泡、带头像与署名。
/// 每个可点元素各占列表的一行，所以一轮几十步也只挂看得见的那些行。
///
/// 审批、提问与计划审批的卡片不在这里画：`card` 是它们的插入点，由审批任务提供。
public struct TranscriptView<Card: View>: View {
    private let model: TranscriptModel
    private let agentName: String
    private let card: (TranscriptCard) -> Card

    @State private var userIsScrolling = false

    /// - Parameters:
    ///   - agentName: 署名（由宿主给出）。
    ///   - card: 审批 / 提问 / 计划审批卡片的视图。
    public init(model: TranscriptModel, agentName: String, @ViewBuilder card: @escaping (TranscriptCard) -> Card) {
        self.model = model
        self.agentName = agentName
        self.card = card
    }

    public var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.rows) { row in
                    TranscriptRowView(row: row, agentName: agentName, model: model, card: card)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .id(row.id)
                        .onAppear {
                            if row.id == model.rows.first?.id { Task { await model.loadOlder() } }
                        }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(.token(.bg))
            .onScrollPhaseChange { _, phase in
                userIsScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 32
            } action: { _, atBottom in
                // 只认用户自己的滚动：内容增长把底部推远不算「上滚」。
                guard userIsScrolling else { return }
                if atBottom { model.reachedBottom() } else { model.userScrolledAway() }
            }
            .onChange(of: model.rows) {
                guard model.follow.isFollowing, let last = model.rows.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .safeAreaInset(edge: .bottom) {
                if !model.follow.isFollowing {
                    JumpToLatestButton(unseen: model.follow.unseen) {
                        model.jumpToLatest()
                        if let last = model.rows.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .task { await model.start() }
    }
}

extension TranscriptView where Card == EmptyView {
    /// 不带卡片视图：卡片行留空。
    public init(model: TranscriptModel, agentName: String) {
        self.init(model: model, agentName: agentName) { _ in EmptyView() }
    }
}

/// 回到最新：上滚离开底部时出现，标明其间新增了多少。
private struct JumpToLatestButton: View {
    let unseen: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
                if unseen > 0 {
                    Text("transcript.jumpToLatest \(unseen)", tableName: "Conversation", bundle: .module)
                } else {
                    Text("transcript.jumpToLatest", tableName: "Conversation", bundle: .module)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.token(.onAccent))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.token(.accent), in: Capsule())
        }
        .hitTarget()
    }
}
