import AgentreDesign
import SwiftUI

extension View {
    /// 稿子的底部面板：`surface` 底、圆角 26、顶上一枚抓手，高度贴合内容而不停在半屏档留大片空白
    /// （规格「全局框架」）。内容比屏幕还高时由系统封顶在全屏档，内容在面板里滚动。
    public func fittedSheet(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        sheet(isPresented: isPresented) { FittedSheetBody(content: content()) }
    }

    /// 按条目呈现的底部面板，其余同 `fittedSheet(isPresented:content:)`。
    public func fittedSheet<Item: Identifiable>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> some View) -> some View {
        sheet(item: item) { item in FittedSheetBody(content: content(item)) }
    }
}

/// 面板本体：量出内容的自然高度，把它作为面板唯一的一档。内容放在滚动视图里：模型很多、或系统字号放大时
/// 面板封顶在全屏档，超出的行仍滚得到，而不是被裁在屏幕下沿之外（规格「界面支持系统字号放大」）。
struct FittedSheetBody<Content: View>: View {
    let content: Content
    @State private var contentHeight: CGFloat?

    /// 抓手一行连同上下留白：上 10、抓手 4、抓手下 18。
    private static var grabberHeight: CGFloat { 10 + 4 + 18 }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.token(.lineStrong))
                .frame(width: 38, height: 4)
                .padding(.bottom, 18)
                .accessibilityHidden(true)
            ScrollView {
                content
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents(contentHeight.map { [.height($0 + Self.grabberHeight)] } ?? [.medium])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(26)
        .presentationBackground(.token(.surface))
    }
}
