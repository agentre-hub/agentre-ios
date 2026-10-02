import AgentreDesign
import AgentreDomain
import SwiftUI

/// `IdentityGlyph` 落到哪一枚 `ColorToken`：领域层只知道「第几档身份色」或「中性」，
/// 把它换成具体 token 是表现层的事（`AgentreDomain` 不依赖 `AgentreDesign`）。
extension IdentityColor {
    var token: ColorToken {
        switch self {
        case .neutral: .agentNeutral
        case .slot(let n):
            // `IdentityColor(wireToken:)` 只在 1...16 内造 `.slot`，这里仍兜一手：
            // 越界不该让整块界面崩掉，退到中性与解析失败时的兜底一致。
            Self.slots.indices.contains(n - 1) ? Self.slots[n - 1] : .agentNeutral
        }
    }

    /// `agent-1`…`agent-16` 顺位对应的 token；`IdentityColor.slot` 只在这个范围内取值。
    private static let slots: [ColorToken] = [
        .agent1, .agent2, .agent3, .agent4, .agent5, .agent6, .agent7, .agent8,
        .agent9, .agent10, .agent11, .agent12, .agent13, .agent14, .agent15, .agent16,
    ]
}

/// `AvatarGlyph` 该画什么：视图与测试共用同一份换算，视图本身只管照着画（规格「全局框架」头像字形一条）。
struct AvatarGlyphAppearance: Equatable {
    enum Fill: Equatable {
        /// 项目或 Agent 解出来了：填它的身份色。
        case identity(ColorToken)
        /// 不属于任何项目：中性填色。
        case neutral
        /// 项目已挂但项目树还没取到：不填色，只描边——空白不是中性，是「此刻不知道」。
        case blank
    }

    let fill: Fill
    let letter: String?

    init(_ glyph: IdentityGlyph) {
        switch glyph {
        case .identity(let letter, let color):
            fill = .identity(color.token)
            self.letter = letter
        case .neutral:
            fill = .neutral
            letter = nil
        case .blank:
            fill = .blank
            letter = nil
        }
    }
}

/// 字形的圆角与字号随边长等比：稿子里 50 / 42 / 34 的字形分别是圆角 16 / 13 / 11、字号 15 / 13 / 11.5。
struct AvatarGlyphMetrics: Equatable {
    let cornerRadius: CGFloat
    let letterSize: CGFloat

    /// 圆角取边长的 0.32；字号在 34→11.5 与 50→15 两端之间线性取（42 落在 13.2）。
    init(size: CGFloat) {
        cornerRadius = size * 0.32
        letterSize = 4 + size * 0.22
    }
}

/// 会话、项目与 Agent 共用的身份字形：项目/Agent 的身份色加首字，不属于任何项目的中性字形，
/// 或项目已挂但列表还没取到时的空白字形（规格「全局框架」头像字形一条）。
///
/// 只管画：字母与颜色由 `IdentityGlyph`（`AgentreDomain`）的纯函数解出，这里不查任何目录。
public struct AvatarGlyph: View {
    private let appearance: AvatarGlyphAppearance
    private let size: CGFloat

    public init(_ glyph: IdentityGlyph, size: CGFloat = 28) {
        appearance = AvatarGlyphAppearance(glyph)
        self.size = size
    }

    private var metrics: AvatarGlyphMetrics { AvatarGlyphMetrics(size: size) }

    public var body: some View {
        ZStack {
            shape
            if let letter = appearance.letter {
                Text(letter)
                    .font(.agentre(FontRole(size: metrics.letterSize, weight: .semibold, relativeTo: .footnote)))
                    .foregroundStyle(.token(.agentInk))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        // 字形本身不念给读屏听：它装饰的那一行（会话标题、Agent 名）已经带着可及名。
        .accessibilityHidden(true)
    }

    @ViewBuilder private var shape: some View {
        let corner = metrics.cornerRadius
        switch appearance.fill {
        case .identity(let token):
            RoundedRectangle(cornerRadius: corner).fill(.token(token))
        case .neutral:
            RoundedRectangle(cornerRadius: corner).fill(.token(.surface2))
        case .blank:
            RoundedRectangle(cornerRadius: corner).strokeBorder(.token(.line))
        }
    }
}
