import AgentreDesign
import AgentreDomain
import SwiftUI

/// 对话的输入区：排队条（或轮末未发送的那几条）、就地候选、输入框与发送，下方常驻一行——
/// 面板入口、权限模式 / 模型 / 思考档位三枚图标（不带文字），右端上下文环。
/// 常驻行负责「点得到」，各项当前取值由面板逐行标注（规格「逐屏视觉契约·02 对话」输入区）。
public struct ComposerView: View {
    @Bindable private var model: ComposerModel
    private let contextUsage: ContextUsage?
    private let onDeleted: () -> Void
    @State private var panel: ComposerPanel.Page?
    @Environment(\.isOffline) private var isOffline
    @Environment(\.locale) private var locale

    /// - Parameters:
    ///   - contextUsage: 任务 6 的上下文用量（`TranscriptModel.contextUsage`）；nil 时环整块不渲染。
    ///   - onDeleted: 会话已删除，离开这一屏。导航归宿主。
    public init(model: ComposerModel, contextUsage: ContextUsage?, onDeleted: @escaping () -> Void) {
        self.model = model
        self.contextUsage = contextUsage
        self.onDeleted = onDeleted
    }

    public var body: some View {
        VStack(spacing: 8) {
            // 上一轮没发出去的还等着处置时，这一轮排着的照样列出来：它们要看得见、撤得掉。
            if !model.queue.dropped.isEmpty { droppedSection }
            if !model.queue.items.isEmpty { queuedSection }
            if !model.candidates.isEmpty { candidateList }
            if isOffline {
                ComposerOfflineText().padding(.horizontal, 14)
            } else if let failure = model.failure {
                ComposerFailureText(failure: failure).padding(.horizontal, 14)
            }
            inputRow
            permanentRow
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 12)
        .background(.token(.bg))
        .overlay(alignment: .top) { Rectangle().fill(.token(.line)).frame(height: 1) }
        .task { if model.settings == nil { await model.load() } }
        .onChange(of: locale, initial: true) { _, locale in model.locale = locale }
        .fittedSheet(item: $panel) { page in
            ComposerPanel(model: model, contextUsage: contextUsage, initialPage: page, onDeleted: onDeleted)
        }
    }

    // MARK: 排队

    /// 稿子的 QueuedBar：`surface` 圆角卡片，一枚图标、条数与「AI 完成后插入」，末尾一枚收起指示（装饰用，
    /// 排着的几条照旧常驻——它们要撤得掉，不是这里能折叠的）。
    private var queuedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(.listPlus)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.token(.ink3))
                    .accessibilityHidden(true)
                Text("composer.queued \(model.queue.items.count)", tableName: composerTable, bundle: .module)
                    .font(.agentre(.footnote))
                    .foregroundStyle(.token(.ink2))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(.chevronUp)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.token(.ink3))
                    .accessibilityHidden(true)
            }
            ForEach(model.queue.items) { item in
                HStack(spacing: 8) {
                    Text(verbatim: ComposerMentions.displayText(item.text))
                        .font(.agentre(.subheadline))
                        .foregroundStyle(.token(.ink))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.cancellable {
                        Button {
                            Task { await model.cancelQueued(item.id) }
                        } label: {
                            Image(.arrowUp)
                                .rotationEffect(.degrees(135))
                                .foregroundStyle(.token(.ink2))
                                .accessibilityLabel(Text("composer.cancelQueued", tableName: composerTable, bundle: .module))
                        }
                        .hitTarget()
                    } else {
                        Image(systemName: "lock")
                            .font(.agentre(.footnote))
                            .foregroundStyle(.token(.ink2))
                            .frame(width: minimumHitTargetSide, height: minimumHitTargetSide)
                            .accessibilityLabel(Text("composer.notCancellable", tableName: composerTable, bundle: .module))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.token(.line)))
    }

    private var droppedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("composer.dropped \(model.queue.dropped.count)", tableName: composerTable, bundle: .module)
                    .font(.agentre(.footnote, weight: .semibold))
                    .foregroundStyle(.token(.coral))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: model.discardDropped) {
                    Text("composer.discard", tableName: composerTable, bundle: .module)
                        .font(.agentre(.footnote))
                        .foregroundStyle(.token(.coral))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
                Button(action: model.restoreDropped) {
                    Text("composer.restore", tableName: composerTable, bundle: .module)
                        .font(.agentre(.footnote, weight: .semibold))
                        .foregroundStyle(.token(.primary))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
            }
            ForEach(model.queue.dropped) { item in
                Text(verbatim: ComposerMentions.displayText(item.text))
                    .font(.agentre(.subheadline))
                    .foregroundStyle(.token(.ink2))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.token(.line)))
    }

    // MARK: 候选

    private var candidateList: some View {
        VStack(spacing: 0) {
            ForEach(model.candidates.prefix(6)) { candidate in
                Button {
                    model.select(candidate)
                } label: {
                    ComposerCandidateRow(candidate: candidate)
                }
                .hitTarget()
            }
        }
        .padding(.horizontal, 8)
        .background(.token(.surface), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.token(.line)))
    }

    // MARK: 输入

    private var placeholderFont: FontRole { FontRole(size: 14.5, relativeTo: .body) }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 9) {
            ComposerTextField(
                text: model.text, cursor: model.cursor,
                placeholder: LocalizedCopy("composer.message", table: composerTable)
            ) { text, cursor in
                model.edit(text: text, cursor: cursor)
            }
            .overlay(alignment: .leading) {
                if model.text.isEmpty {
                    Text("composer.message", tableName: composerTable, bundle: .module)
                        .font(.agentre(placeholderFont))
                        .foregroundStyle(.token(.ink3))
                        .padding(.leading, 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(.token(.surface), in: Capsule())
            .overlay(Capsule().strokeBorder(.token(.line)))
            // 停止本轮：只在一轮真的在跑时摆——闲着的时候没有什么可停。与排队并存，不替换发送。
            if model.isTurnRunning {
                Button {
                    Task { await model.stop() }
                } label: {
                    Image(.square)
                        .resizable()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.token(model.canStop && !isOffline ? .coral : .ink3))
                        .padding(11.5)
                        .background(.token(.surface2), in: Circle())
                        .overlay(Circle().strokeBorder(.token(.lineStrong)))
                        .accessibilityLabel(Text("composer.stop", tableName: composerTable, bundle: .module))
                }
                .hitTarget()
                .disabled(!model.canStop || isOffline)
            }
            Button {
                Task { await model.send() }
            } label: {
                let canSend = model.canSend && !isOffline
                Image(.arrowUp)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.token(canSend ? .primaryInk : .ink2))
                    .padding(10)
                    .background(.token(canSend ? .primary : .surface2), in: Circle())
                    .accessibilityLabel(Text("composer.send", tableName: composerTable, bundle: .module))
            }
            .hitTarget()
            .disabled(!model.canSend || isOffline)
        }
    }

    private var permanentRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                toolButton(.plus, "composer.more", page: .root, filled: true)
                toolButton(.shieldCheck, "composer.permissionMode", page: .permissionMode)
                toolButton(.cpu, "composer.model", page: .model)
                toolButton(.brain, "composer.effort", page: .effort)
            }
            Spacer(minLength: 0)
            ContextRingView(usage: contextUsage)
        }
    }

    /// 一枚工具行按钮：`+`（展开面板）实心填底，其余三项（权限模式 / 模型 / 思考档位）透明底，
    /// 只用图标区分（规格「02 对话」输入区，稿子 ActionRow）。
    private func toolButton(_ icon: AgentreIcon, _ label: LocalizedStringKey, page: ComposerPanel.Page, filled: Bool = false) -> some View {
        Button {
            self.panel = page
        } label: {
            Image(icon)
                .resizable()
                .frame(width: 20, height: 20)
                .foregroundStyle(.token(filled ? .ink : .ink2))
                .padding(8)
                .background(filled ? .token(.surface2) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(Text(label, tableName: composerTable, bundle: .module))
        }
        .hitTarget()
    }
}

/// 一条候选：命令或名字以等宽呈现，说明（或设备离线）在后。
private struct ComposerCandidateRow: View {
    let candidate: ComposerModel.Candidate

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: candidate.title)
                .font(.agentre(.subheadline, mono: true))
                .foregroundStyle(.token(.ink))
            switch candidate.kind {
            case .slash(let command):
                Text(verbatim: command.description)
                    .font(.agentre(.footnote))
                    .foregroundStyle(.token(.ink2))
                    .lineLimit(1)
            case .mention(let mention):
                if mention.online == false {
                    Text("composer.offline", tableName: composerTable, bundle: .module)
                        .font(.agentre(.footnote))
                        .foregroundStyle(.token(.ink2))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 离线：输入照常，发不出去——只陈述这个事实。
struct ComposerOfflineText: View {
    var body: some View {
        Label {
            Text("composer.deviceOffline", tableName: composerTable, bundle: .module)
        } icon: {
            Image(systemName: "wifi.slash")
        }
        .font(.agentre(.footnote))
        .foregroundStyle(.token(.ink2))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 没办成的那件事，只陈述事实。
struct ComposerFailureText: View {
    let failure: ComposerModel.Failure

    var body: some View {
        Group {
            switch failure {
            case .send: Text("composer.sendFailed", tableName: composerTable, bundle: .module)
            case .change: Text("composer.changeFailed", tableName: composerTable, bundle: .module)
            case .delete: Text("composer.deleteFailed", tableName: composerTable, bundle: .module)
            }
        }
        .font(.agentre(.footnote))
        .foregroundStyle(.token(.coral))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
