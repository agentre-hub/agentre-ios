import AgentreDesign
import AgentreDomain
import SwiftUI

/// 「我」（页标题「账号」，tab 仍叫「我」）：首字头像卡、四个分组行各进二级页
/// （服务器 / 已授权设备 / 语言 / 外观）、关于只显示版本号，底部是 `coral` 描边的退出登录
/// （规格「逐屏视觉契约·09 我」、决策 22）。
public struct MeView: View {
    private let model: MeModel
    private let navigate: (MeRoute) -> Void

    /// - Parameter navigate: 二级页去处交给宿主决定怎么入栈（装配层按值 push 进 `Router.me`）。
    public init(model: MeModel, navigate: @escaping (MeRoute) -> Void) {
        self.model = model
        self.navigate = navigate
    }

    // 命中区检查器（AgentreTestSupport，任务 2/4 冻结）在 ScrollView 里看不到任何元素，只在 List 里看得到；
    // 因此这一屏用 List 铺卡片，而不是 ScrollView + VStack。行与卡片背景经 listRow* 修饰符清空系统样式。
    public var body: some View {
        List {
            if let failure = model.failure {
                FailureNotice(fact: failure) { Task { await model.load() } }
                    .padding(16)
                    .background(.token(.surface), in: RoundedRectangle(cornerRadius: 18))
                    .rowStyled()
            }
            if let profile = model.profile {
                accountCard(profile)
                    .rowStyled()
            }
            GroupedSection {
                GroupedRow(
                    .globe, title: Text("me.server", tableName: "Me", bundle: .module),
                    value: Text(verbatim: model.serverAddress.hostOnly), monoValue: true
                ) { navigate(.server) }
                GroupedRow(
                    .smartphone, title: Text("me.devices", tableName: "Me", bundle: .module),
                    value: Text(verbatim: "\(model.devices.count)")
                ) { navigate(.devices) }
            }
            .rowStyled()
            GroupedSection {
                GroupedRow(
                    .languages, title: Text("me.language", tableName: "Me", bundle: .module),
                    value: Text(model.preferences.language.labelKey, tableName: "Me", bundle: .module)
                ) { navigate(.language) }
                GroupedRow(
                    .sunMoon, title: Text("me.appearance", tableName: "Me", bundle: .module),
                    value: Text(model.preferences.appearance.labelKey, tableName: "Me", bundle: .module)
                ) { navigate(.appearance) }
            }
            .rowStyled()
            GroupedSection {
                AboutRow(version: model.version)
            }
            .rowStyled()
            signOutButton
                .rowStyled()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(.token(.bg))
        .task { await model.load() }
    }

    @ViewBuilder private func accountCard(_ profile: AccountProfile) -> some View {
        HStack(spacing: 14) {
            InitialAvatar(name: profile.shownName)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: profile.shownName)
                    .font(.agentre(FontRole(size: 17, weight: .semibold, relativeTo: .headline)))
                    .foregroundStyle(.token(.ink))
                    .lineLimit(1)
                // 副行写邮箱：GitHub 是唯一的登录方式，「通过 GitHub 授权」删掉用户什么也不少知道（决策 19）。
                Text(verbatim: profile.email)
                    .font(.agentre(FontRole(size: 12.5, relativeTo: .footnote)))
                    .foregroundStyle(.token(.ink2))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private var signOutButton: some View {
        Button {
            Task { await model.signOut() }
        } label: {
            HStack(spacing: 8) {
                Image(.logOut)
                    .resizable()
                    .frame(width: 16, height: 16)
                Text("me.signOut", tableName: "Me", bundle: .module)
                    .font(.agentre(FontRole(size: 15, weight: .medium, relativeTo: .subheadline)))
            }
            .foregroundStyle(.token(.coral))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 16).strokeBorder(.token(.line)))
        }
        .hitTarget()
    }
}

/// 首字头像：账号卡专用，`primary-dim` 底、`primary` 字（规格「09 我」），与项目/Agent 的身份色字形是两回事。
private struct InitialAvatar: View {
    let name: String

    var body: some View {
        Circle()
            .fill(.token(.primaryDim))
            .frame(width: 52, height: 52)
            .overlay {
                if let letter = name.first {
                    Text(String(letter).uppercased())
                        .font(.agentre(FontRole(size: 20, weight: .semibold, relativeTo: .title2)))
                        .foregroundStyle(.token(.primary))
                }
            }
            .accessibilityHidden(true)
    }
}

/// 「关于」一行：等宽版本号，不可点（规格「09 我」）。视觉上与其它分组行同款（图标、标题、取值、展开指示），
/// 但不是 `Button`——它不在命中区清单里，点它什么也不会发生。
private struct AboutRow: View {
    let version: String

    var body: some View {
        HStack(spacing: 12) {
            Image(.info)
                .resizable()
                .frame(width: 17, height: 17)
                .foregroundStyle(.token(.ink3))
                .accessibilityHidden(true)
            Text("me.about", tableName: "Me", bundle: .module)
                .font(.agentre(FontRole(size: 15, relativeTo: .body)))
                .foregroundStyle(.token(.ink))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: version)
                .font(.agentre(FontRole(size: 12.5, relativeTo: .subheadline), mono: true))
                .foregroundStyle(.token(.ink3))
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// List 行去掉系统样式，只保留左右外边距；卡片之间的间距靠内容自身的垂直内边距撑开
    /// （List 不像 VStack 那样能直接给 `spacing`）。
    fileprivate func rowStyled() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .padding(.vertical, 10)
    }
}

extension ServerAddress {
    /// 登录屏与「我」页只承诺主机名，不带协议、端口与路径（规格「07 登录」「09 我」，
    /// 数据源核实：`ServerAddress.url.host`）。
    var hostOnly: String { url.host ?? url.absoluteString }
}
