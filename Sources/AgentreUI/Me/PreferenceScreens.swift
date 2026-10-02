import AgentreDesign
import AgentreDomain
import SwiftUI

/// 「语言」二级页：选项即时生效、当前取值打勾。
public struct LanguageScreen: View {
    private let model: MeModel

    public init(model: MeModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section {
                ForEach(DisplayLanguage.allCases, id: \.self) { language in
                    PreferenceOptionRow(label: language.labelKey, selected: model.preferences.language == language) {
                        model.setLanguage(language)
                    }
                    .listRowBackground(Color.token(.surface))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.token(.bg))
    }
}

/// 「外观」二级页：选项即时生效、当前取值打勾。
public struct AppearanceScreen: View {
    private let model: MeModel

    public init(model: MeModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section {
                ForEach(DisplayAppearance.allCases, id: \.self) { appearance in
                    PreferenceOptionRow(label: appearance.labelKey, selected: model.preferences.appearance == appearance) {
                        model.setAppearance(appearance)
                    }
                    .listRowBackground(Color.token(.surface))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.token(.bg))
    }
}

/// 语言 / 外观共用的一行选项：标题与选中打勾，整行是命中区补满 44 的按钮。
private struct PreferenceOptionRow: View {
    let label: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label, tableName: "Me", bundle: .module)
                    .font(.agentre(.body))
                    .foregroundStyle(.token(.ink))
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(.token(.primary))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .hitTarget()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
