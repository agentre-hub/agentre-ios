import AgentreDesign
import AgentreDomain
import SwiftUI

/// 对话的输入区：排队条（或轮末未发送的那几条）、就地候选、输入框与发送，下方常驻一行——
/// 面板入口、权限模式 / 模型 / 思考档位三枚图标（不带文字），右端上下文环。
/// 常驻行负责「点得到」，各项当前取值由面板逐行标注。
public struct ComposerView: View {
    @Bindable private var model: ComposerModel
    private let contextUsage: ContextUsage?
    private let onDeleted: () -> Void
    @State private var panel: ComposerPanel.Page?
    @Environment(\.isOffline) private var isOffline

    /// - Parameters:
    ///   - contextUsage: 任务 6 的上下文用量（`TranscriptModel.contextUsage`）；nil 时环整块不渲染。
    ///   - onDeleted: 会话已删除，离开这一屏。导航归宿主。
    public init(model: ComposerModel, contextUsage: ContextUsage?, onDeleted: @escaping () -> Void) {
        self.model = model
        self.contextUsage = contextUsage
        self.onDeleted = onDeleted
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 上一轮没发出去的还等着处置时，这一轮排着的照样列出来：它们要看得见、撤得掉。
            if !model.queue.dropped.isEmpty { droppedSection }
            if !model.queue.items.isEmpty { queuedSection }
            if !model.candidates.isEmpty { candidateList }
            if isOffline {
                ComposerOfflineText().padding(.horizontal, 16).padding(.top, 4)
            } else if let failure = model.failure {
                ComposerFailureText(failure: failure).padding(.horizontal, 16).padding(.top, 4)
            }
            inputRow
            permanentRow
        }
        .background(.token(.bg))
        .task { if model.settings == nil { await model.load() } }
        .sheet(item: $panel) { page in
            ComposerPanel(model: model, contextUsage: contextUsage, initialPage: page, onDeleted: onDeleted)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: 排队

    private var queuedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text("composer.queued \(model.queue.items.count)", tableName: composerTable, bundle: .module)
            } icon: {
                Image(systemName: "hourglass")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.token(.textSecondary))
            .padding(.vertical, 6)
            ForEach(model.queue.items) { item in
                HStack(spacing: 8) {
                    Text(verbatim: ComposerMentions.displayText(item.text))
                        .font(.subheadline)
                        .foregroundStyle(.token(.textPrimary))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.cancellable {
                        Button {
                            Task { await model.cancelQueued(item.id) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote)
                                .foregroundStyle(.token(.textSecondary))
                                .accessibilityLabel(Text("composer.cancelQueued", tableName: composerTable, bundle: .module))
                        }
                        .hitTarget()
                    } else {
                        Image(systemName: "lock")
                            .font(.footnote)
                            .foregroundStyle(.token(.textSecondary))
                            .frame(width: minimumHitTargetSide, height: minimumHitTargetSide)
                            .accessibilityLabel(Text("composer.notCancellable", tableName: composerTable, bundle: .module))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .background(.token(.surface))
    }

    private var droppedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("composer.dropped \(model.queue.dropped.count)", tableName: composerTable, bundle: .module)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.token(.failure))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: model.discardDropped) {
                    Text("composer.discard", tableName: composerTable, bundle: .module)
                        .font(.footnote)
                        .foregroundStyle(.token(.failure))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
                Button(action: model.restoreDropped) {
                    Text("composer.restore", tableName: composerTable, bundle: .module)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.token(.accent))
                        .padding(.horizontal, 8)
                }
                .hitTarget()
            }
            ForEach(model.queue.dropped) { item in
                Text(verbatim: ComposerMentions.displayText(item.text))
                    .font(.subheadline)
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .background(.token(.surface))
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
        .background(.token(.surface))
    }

    // MARK: 输入

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerTextField(
                text: model.text, cursor: model.cursor,
                placeholder: String(localized: "composer.message", table: composerTable, bundle: .module)
            ) { text, cursor in
                model.edit(text: text, cursor: cursor)
            }
            .overlay(alignment: .leading) {
                if model.text.isEmpty {
                    Text("composer.message", tableName: composerTable, bundle: .module)
                        .foregroundStyle(.token(.textSecondary))
                        .padding(.leading, 13)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(.token(.surface), in: RoundedRectangle(cornerRadius: 22))
            // 停止本轮：只在一轮真的在跑时摆——闲着的时候没有什么可停。与排队并存，不替换发送。
            if model.isTurnRunning {
                Button {
                    Task { await model.stop() }
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.title)
                        .foregroundStyle(.token(model.canStop ? .textPrimary : .textSecondary))
                        .accessibilityLabel(Text("composer.stop", tableName: composerTable, bundle: .module))
                }
                .hitTarget()
                .disabled(!model.canStop || isOffline)
            }
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(.token(model.canSend && !isOffline ? .accent : .textSecondary))
                    .accessibilityLabel(Text("composer.send", tableName: composerTable, bundle: .module))
            }
            .hitTarget()
            .disabled(!model.canSend || isOffline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var permanentRow: some View {
        HStack(spacing: 0) {
            icon("slider.horizontal.3", "composer.more", page: .root)
            icon("lock.shield", "composer.permissionMode", page: .permissionMode)
            icon("cpu", "composer.model", page: .model)
            icon("brain", "composer.effort", page: .effort)
            Spacer(minLength: 0)
            ContextRingView(usage: contextUsage)
        }
        .padding(.horizontal, 8)
    }

    private func icon(_ systemImage: String, _ label: LocalizedStringKey, page: ComposerPanel.Page) -> some View {
        Button {
            panel = page
        } label: {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.token(.textSecondary))
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
                .font(.subheadline.monospaced())
                .foregroundStyle(.token(.textPrimary))
            switch candidate.kind {
            case .slash(let command):
                Text(verbatim: command.description)
                    .font(.footnote)
                    .foregroundStyle(.token(.textSecondary))
                    .lineLimit(1)
            case .mention(let mention):
                if mention.online == false {
                    Text("composer.offline", tableName: composerTable, bundle: .module)
                        .font(.footnote)
                        .foregroundStyle(.token(.textSecondary))
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
        .font(.footnote)
        .foregroundStyle(.token(.textSecondary))
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
        .font(.footnote)
        .foregroundStyle(.token(.failure))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
