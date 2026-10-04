import AgentreDesign
import AgentreDomain
import SwiftUI

// 对话屏更多面板与草稿工具行共用的部件：同一张人话表、同一份译文、同一种选项行与返回行。
// 两处各留一份时已经各自走样过，所以只在这里定义。

/// 权限档位与思考档位的人话。
enum SettingCopy {
    /// 权限档位人话：表内已知档位取本地化名（非等宽），表外原样等宽（规格「04 更多面板」）。
    static func permissionMode(_ mode: String) -> (text: Text, mono: Bool) {
        switch PermissionModeDisplay(mode) {
        case .standard(.`default`): (Text("composer.permissionMode.default", tableName: composerTable, bundle: .module), false)
        case .standard(.acceptEdits): (Text("composer.permissionMode.acceptEdits", tableName: composerTable, bundle: .module), false)
        case .standard(.plan): (Text("composer.permissionMode.plan", tableName: composerTable, bundle: .module), false)
        case .standard(.bypassPermissions): (Text("composer.permissionMode.bypassPermissions", tableName: composerTable, bundle: .module), false)
        case .raw(let value): (Text(verbatim: value), true)
        }
    }

    /// 思考档位人话：低/中/高非等宽，会话未设定（空）时标「默认」，执行端报出的更高档原样等宽。
    static func reasoningEffort(_ effort: String) -> (text: Text, mono: Bool) {
        guard !effort.isEmpty else { return (Text("composer.effort.default", tableName: composerTable, bundle: .module), false) }
        switch ReasoningEffortDisplay(effort) {
        case .standard(.low): return (Text("composer.effort.low", tableName: composerTable, bundle: .module), false)
        case .standard(.medium): return (Text("composer.effort.medium", tableName: composerTable, bundle: .module), false)
        case .standard(.high): return (Text("composer.effort.high", tableName: composerTable, bundle: .module), false)
        case .raw(let value): return (Text(verbatim: value), true)
        }
    }
}

/// 选项页一行的文字：表内的档位只写人话，不附原串；表外的原样等宽（规格「04 更多面板」）。
struct SettingOptionLabel: View {
    let display: (text: Text, mono: Bool)
    /// 不再显示：草稿工具行（Composer 目录之外）仍按旧签名传入，由它的所有者收掉。
    var raw: String?

    var body: some View {
        display.text.font(.agentre(.body, mono: display.mono))
    }
}

/// 选项页的一行：当前值打勾。外层由 `GroupedSection` 给背景、圆角与分隔线。
/// `disabledWhenOffline`：选了就要写到机器上的（对话屏）离线时点不动；只改本机草稿的不受影响。
struct SettingSelectionRow<Label: View>: View {
    let selected: Bool
    var disabledWhenOffline = false
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.isOffline) private var isOffline

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                label.foregroundStyle(.token(.ink))
                Spacer(minLength: 8)
                if selected {
                    Image(.check)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.token(.primary))
                }
            }
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
            .frame(maxWidth: .infinity)
        }
        .hitTarget()
        .disabled(disabledWhenOffline && isOffline)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 选项页顶上的返回：回到面板根上。
struct SettingsPageBack: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(.chevronLeft)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .accessibilityLabel(Text("composer.back", tableName: composerTable, bundle: .module))
                Text(title, tableName: composerTable, bundle: .module).font(.agentre(.headline))
            }
            .foregroundStyle(.token(.ink))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .hitTarget()
    }
}
