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
            .onScrollGeometryChange(for: ScrollPosition.self) { geometry in
                // 可见区要扣掉底部内边距：键盘、安全区与「回到最新」都落在这里，容器高度本身不随它们变。
                let visibleHeight = geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
                return ScrollPosition(
                    offset: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    visibleHeight: visibleHeight,
                    atBottom: geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom >= geometry.contentSize.height - 32
                )
            } action: { old, new in
                // 跟随中布局变了（键盘弹回、回前台、行高落定）：重新贴到最新一行。行变化另由下面的 onChange 贴。
                if model.follow.isFollowing, new.contentHeight > 0,
                   abs(new.visibleHeight - old.visibleHeight) >= 1 || abs(new.contentHeight - old.contentHeight) >= 1,
                   let last = model.rows.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                // 只认内容不变时视口自己的移动：内容增减（含首次布局、补进历史）带动的偏移不算滚动。
                // 移到底部即恢复跟随；离开底部只认往上走——跟随的滚动只往下走。
                // 首次布局时内容还是空的，安全区内边距会把偏移挪一下，那不是滚动。
                guard new.contentHeight > 0, abs(new.contentHeight - old.contentHeight) < 1, abs(new.offset - old.offset) > 1 else { return }
                if new.atBottom {
                    if !model.follow.isFollowing { model.reachedBottom() }
                } else if new.offset < old.offset, model.follow.isFollowing {
                    model.userScrolledAway()
                }
            }
            .onChange(of: model.rows) {
                guard model.follow.isFollowing, let last = model.rows.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .safeAreaInset(edge: .bottom) {
                if !model.follow.isFollowing {
                    JumpToLatestButton(unseen: model.follow.unseen) {
                        if let last = model.rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        model.jumpToLatest()
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

/// 视口相对内容的位置。
fileprivate struct ScrollPosition: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    /// 扣掉上下内边距后的可见高度。
    var visibleHeight: CGFloat
    var atBottom: Bool
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
