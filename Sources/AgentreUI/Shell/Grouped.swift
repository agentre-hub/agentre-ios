import AgentreDesign
import SwiftUI

/// 分组卡片出现在哪里：两处的底色、圆角与行距按稿子各不相同。
public enum GroupedStyle: Sendable {
    /// 页面上（「我」）：`surface` 底、圆角 18。
    case page
    /// 底部面板里：`bg` 底加 `line` 描边、圆角 16，行略紧。
    case sheet

    fileprivate var fill: ColorToken { self == .page ? .surface : .bg }
    fileprivate var corner: CGFloat { self == .page ? 18 : 16 }
    fileprivate var verticalPadding: CGFloat { self == .page ? 4 : 0 }
    fileprivate var rowPadding: EdgeInsets {
        self == .page ? EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16) : EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14)
    }
    fileprivate var rowSpacing: CGFloat { self == .page ? 12 : 11 }
    fileprivate var titleSize: CGFloat { self == .page ? 15 : 14.5 }
    fileprivate var valueSize: CGFloat { self == .page ? 14 : 13.5 }
    fileprivate var monoValueSize: CGFloat { self == .page ? 12.5 : 12 }
    fileprivate var chevronSize: CGFloat { self == .page ? 16 : 15 }
}

extension EnvironmentValues {
    @Entry var groupedStyle: GroupedStyle = .page
}

/// 一张分组圆角卡片：行与行之间一条 `line` 分隔（规格「全局框架」：行排在分组圆角卡片里）。
public struct GroupedSection<Content: View>: View {
    private let style: GroupedStyle
    private let content: Content

    public init(style: GroupedStyle = .page, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(.token(.line)).frame(height: 1)
                    }
                    row
                }
            }
        }
        .padding(.vertical, style.verticalPadding)
        .environment(\.groupedStyle, style)
        .background(.token(style.fill), in: RoundedRectangle(cornerRadius: style.corner))
        .overlay {
            if style == .sheet {
                RoundedRectangle(cornerRadius: style.corner).strokeBorder(.token(.line))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: style.corner))
    }
}

/// 分组卡片里的一行：左侧一枚线性图标、标题，右侧取值与展开指示；整行是一个命中区补满 44 的按钮。
/// 破坏性的一行（删除会话）整行 `coral`，不带取值与展开指示。
public struct GroupedRow: View {
    public enum Role: Sendable {
        case standard, destructive
    }

    private let icon: AgentreIcon
    private let title: Text
    private let value: Text?
    private let monoValue: Bool
    private let role: Role
    private let action: () -> Void
    @Environment(\.groupedStyle) private var style

    /// - Parameter monoValue: 取值是机器字面（模型 ID、地址、版本号）时用等宽字。
    public init(
        _ icon: AgentreIcon, title: Text, value: Text? = nil, monoValue: Bool = false, role: Role = .standard,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.value = value
        self.monoValue = monoValue
        self.role = role
        self.action = action
    }

    public var body: some View {
        let destructive = role == .destructive
        Button(action: action) {
            HStack(spacing: style.rowSpacing) {
                Image(icon)
                    .resizable()
                    .frame(width: 17, height: 17)
                    .foregroundStyle(.token(destructive ? .coral : .ink3))
                    .accessibilityHidden(true)
                title
                    .font(.agentre(FontRole(size: style.titleSize, relativeTo: .body)))
                    .foregroundStyle(.token(destructive ? .coral : .ink))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !destructive {
                    if let value {
                        value
                            .font(.agentre(FontRole(size: monoValue ? style.monoValueSize : style.valueSize, relativeTo: .subheadline), mono: monoValue))
                            .foregroundStyle(.token(.ink3))
                            .lineLimit(1)
                    }
                    Image(.chevronRight)
                        .resizable()
                        .frame(width: style.chevronSize, height: style.chevronSize)
                        .foregroundStyle(.token(.ink3))
                        .accessibilityHidden(true)
                }
            }
            .padding(style.rowPadding)
            .frame(maxWidth: .infinity)
        }
        .hitTarget()
    }
}
