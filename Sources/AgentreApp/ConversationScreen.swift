import AgentreDesign
import AgentreDomain
import AgentreUI
import SwiftUI

/// 对话屏：转录（审批与提问卡片内联其中）、跟随不上时的事实、输入区。
struct ConversationScreen: View {
    let services: SignedInServices
    let key: ConversationKey
    let onDeleted: () -> Void
    @State private var model: ConversationScreenModel?
    @Environment(\.isOffline) private var isOffline

    /// 没有标题的会话以会话 ID 认出；模型还没建好时标题留空（这一瞬间导航栏照样在，返回照样可用）。
    private var title: String {
        guard let model else { return "" }
        return model.conversation.title.isEmpty ? key.conversationID : model.conversation.title
    }

    var body: some View {
        Group {
            if let model {
                VStack(spacing: 0) {
                    TranscriptView(model: model.transcript, agentName: model.agentName) { card in
                        ApprovalCard(card, model: model.cards)
                    }
                    // 离线时由输入区如实说离线；跟随不上的那条事实（连不上服务器、没回应）此刻只是它的后果。
                    if !isOffline, let fact = services.failures.facts[key] {
                        FailureNotice(fact: fact) { Task { await services.resume() } }
                            .padding(.horizontal, 16)
                    }
                    ComposerView(model: model.composer, contextUsage: model.transcript.contextUsage) {
                        services.forget(key)
                        onDeleted()
                    }
                }
            } else {
                Rectangle().fill(.token(.bg))
            }
        }
        .background(.token(.bg))
        .compactNavigationBar(title: Text(verbatim: title))
        .task {
            if model == nil { model = await services.conversationModel(for: key) }
            // 进来就是读过了（不论从消息列表还是机器详情进来）；离开时把开着期间到的活动一并记成已读。
            try? await services.store.markRead(key)
        }
        .onDisappear {
            let store = services.store
            let key = key
            Task { try? await store.markRead(key) }
        }
    }
}
