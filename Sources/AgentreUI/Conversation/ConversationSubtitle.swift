import AgentreDesign
import AgentreDomain
import SwiftUI

/// 对话屏导航栏的副标题（规格「02 对话」）：运行中为绿色「正在输入…」，等你处理为琥珀色「等你回复」，
/// 其余为承载机器名（等宽、次级色）；机器名还不知道时不写。
public enum ConversationSubtitle {
    public static func text(_ activity: ConversationActivity, machineName: String?) -> Text? {
        switch activity {
        case .typing:
            Text("conversation.subtitle.typing", tableName: "Conversation", bundle: .module)
                .foregroundStyle(.token(.run))
        case .waiting:
            Text("conversation.subtitle.waiting", tableName: "Conversation", bundle: .module)
                .foregroundStyle(.token(.amber))
        case .failed, .idle:
            machineName.map {
                Text(verbatim: $0)
                    .font(.agentre(.caption, mono: true))
                    .foregroundStyle(.token(.ink2))
            }
        }
    }
}
