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

    var body: some View {
        Group {
            if let model {
                VStack(spacing: 0) {
                    TranscriptView(model: model.transcript, agentName: model.agentName) { card in
                        ApprovalCard(card, model: model.cards)
                    }
                    if let fact = services.failures.facts[key] {
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
        }
    }
}
