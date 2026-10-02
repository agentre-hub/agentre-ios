import AgentreDesign
import AgentreDomain
import AgentreUI
import SwiftUI

/// 对话屏：转录（审批与提问卡片内联其中）、跟随不上时的事实、输入区。
/// 导航栏是返回、项目字形、标题、随状态的副标题，右侧 ⓘ 打开会话信息。
struct ConversationScreen: View {
    let services: SignedInServices
    let key: ConversationKey
    let onDeleted: () -> Void
    @State private var model: ConversationScreenModel?
    /// 项目树还没取到时是空白字形（我们此刻不知道它属于哪个项目）。
    @State private var glyph = IdentityGlyph.blank
    @State private var machineName: String?
    @State private var showsInfo = false
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
                    TranscriptView(model: model.transcript, agentName: BackendLabel.short(model.conversation.backendType)) { card in
                        ApprovalCard(card, model: model.cards)
                    }
                    // 离线时由输入区如实说离线；跟随不上的那条事实（连不上服务器、没回应）此刻只是它的后果。
                    if !isOffline, let fact = services.failures.facts[key] {
                        FailureNotice(fact: fact) { Task { await services.resume() } }
                            .padding(.horizontal, 16)
                    }
                    ComposerView(model: model.composer, contextUsage: model.transcript.contextUsage, onDeleted: deleted)
                }
                // 还在跑、执行端还没报模型的那一轮署会话此刻的模型。
                .onChange(of: model.composer.settings?.model, initial: true) { _, choice in
                    model.transcript.currentModel = choice.map { $0.modelId.isEmpty ? $0.displayName : $0.modelId }
                }
                .fittedSheet(isPresented: $showsInfo) {
                    ComposerPanel(model: model.composer, contextUsage: model.transcript.contextUsage, initialPage: .sessionInfo, onDeleted: deleted)
                }
            } else {
                Rectangle().fill(.token(.bg))
            }
        }
        .background(.token(.bg))
        .compactNavigationBar(
            title: Text(verbatim: title),
            subtitle: model.flatMap { ConversationSubtitle.text($0.transcript.document.activity, machineName: machineName) },
            leading: { AvatarGlyph(glyph, size: 34) },
            trailing: {
                ChromeIconButton(.info, label: Text("composer.sessionInfo", tableName: "Composer", bundle: AgentreUIResources.bundle), size: 21) {
                    showsInfo = true
                }
                .disabled(model == nil)
            }
        )
        .task {
            if model == nil { model = await services.conversationModel(for: key) }
            // 进来就是读过了（不论从消息列表还是机器详情进来）；离开时把开着期间到的活动一并记成已读。
            try? await services.store.markRead(key)
            guard let conversation = model?.conversation else { return }
            // 目录晚到（冷启动时 REST 还没答、离线后才联网）时，空白字形与副标题里的机器名随之补上。
            let identity = services.identity
            let changes = await identity.changes()
            glyph = IdentityGlyph.project(conversation.projectSyncID, in: await identity.projects())
            machineName = await identity.machineName(fingerprint: conversation.carrierFingerprint)
            for await _ in changes {
                glyph = IdentityGlyph.project(conversation.projectSyncID, in: await identity.projects())
                machineName = await identity.machineName(fingerprint: conversation.carrierFingerprint)
            }
        }
        .onDisappear {
            let store = services.store
            let key = key
            Task { try? await store.markRead(key) }
        }
    }

    private func deleted() {
        services.forget(key)
        onDeleted()
    }
}
