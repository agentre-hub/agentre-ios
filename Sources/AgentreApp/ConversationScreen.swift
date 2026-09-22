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
                .navigationTitle(Text(verbatim: model.conversation.title.isEmpty ? key.conversationID : model.conversation.title))
                .navigationBarTitleDisplayMode(.inline)
            } else {
                Rectangle().fill(.token(.bg))
            }
        }
        .background(.token(.bg))
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
