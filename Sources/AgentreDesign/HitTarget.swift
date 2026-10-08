import SwiftUI

/// 可点区域的最小边长（pt），与绘制尺寸无关。
public let minimumHitTargetSide: CGFloat = 44

extension Button {
    /// 把按钮的命中区扩到至少 44×44pt，绘制尺寸不变。
    ///
    /// 只挂在 `Button` 上、经按钮样式实现，是刻意的：命中区必须补在按钮**里面**（label 上）。
    /// 在按钮外面补 `.frame` + `.contentShape` 只会撑大布局与无障碍框，真实点击区不变
    /// （模拟器实测：离 16pt 图标中心 30pt 处，里面补的两种按钮都响应，外面补的都不响应）。
    public func hitTarget() -> some View {
        buttonStyle(HitTargetButtonStyle())
    }
}

/// 命中区补满 44×44 的按钮样式。按下时降低不透明度作反馈，不改颜色。
public struct HitTargetButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HitTargetBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct HitTargetBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.hitTargetCollector) private var collector
    @State private var id = UUID()

    var body: some View {
        label
            .opacity(isPressed ? 0.6 : 1)
            .frame(minWidth: minimumHitTargetSide, minHeight: minimumHitTargetSide)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                collector?.record(id, frame)
            }
            .onDisappear { collector?.remove(id) }
    }
}

/// 测试用：登记一屏上每块补满后的命中区（窗口坐标）。生产环境没有它，登记为空操作。
@MainActor
public final class HitTargetCollector {
    public private(set) var frames: [UUID: CGRect] = [:]

    public init() {}

    func record(_ id: UUID, _ frame: CGRect) { frames[id] = frame }
    func remove(_ id: UUID) { frames[id] = nil }
}

extension EnvironmentValues {
    @Entry public var hitTargetCollector: HitTargetCollector?
}
