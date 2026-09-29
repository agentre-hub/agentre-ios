import AgentreDesign
import SwiftUI

extension View {
    /// 稿子的底部面板：`surface` 底、圆角 26、顶上一枚抓手，高度贴合内容而不停在半屏档留大片空白
    /// （规格「全局框架」）。内容比屏幕还高时由系统封顶在全屏档。
    public func fittedSheet(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        sheet(isPresented: isPresented) { FittedSheetBody(content: content()) }
    }

    /// 按条目呈现的底部面板，其余同 `fittedSheet(isPresented:content:)`。
    public func fittedSheet<Item: Identifiable>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> some View) -> some View {
        sheet(item: item) { item in FittedSheetBody(content: content(item)) }
    }
}

/// 面板本体：量出内容的自然高度，把它作为面板唯一的一档。
struct FittedSheetBody<Content: View>: View {
    let content: Content
    @State private var height: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.token(.lineStrong))
                .frame(width: 38, height: 4)
                .padding(.bottom, 18)
                .accessibilityHidden(true)
            content
        }
        .padding(.top, 10)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents(height.map { [.height($0)] } ?? [.medium])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(26)
        .presentationBackground(.token(.surface))
    }
}
