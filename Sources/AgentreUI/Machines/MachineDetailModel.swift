import AgentreDomain
import Observation

/// 机器详情上的一行：机器现答的会话，与它此刻在不在手机上。
public struct MachineSessionRow: Sendable, Equatable, Identifiable {
    public let session: MachineSession
    public let key: ConversationKey
    public var isSaved: Bool
    public var isSaving = false
    public var saveFailed = false

    /// 会话号只在发起端内唯一：一台机器上它自己的与它代转的他端的会话可以同号。
    public var id: ConversationKey { key }
}

/// 机器详情：现问那台机器要它的会话与计数，并在这里把一条保存到手机。
@MainActor
@Observable
public final class MachineDetailModel {
    public let machine: Machine
    public private(set) var rows: [MachineSessionRow] = []
    /// 机器现算的三个数；离线或还没答时为 nil——不是零。
    public private(set) var counts: MachineSessionCounts?
    public private(set) var hasMore = false
    public private(set) var keyword = ""
    /// 名册说它在线，中继上却没问到。
    public private(set) var unreachable = false
    /// 没问到的原因是那台机器的协议版本与本 App 不等：要更新 App（此时 `unreachable` 也为真）。
    public private(set) var updateRequired = false

    private let source: any MachineSessionSource
    private let store: any ConversationSaving
    private let saver: ConversationSaver
    private let pageSize: Int
    private var cursor = ""
    private var loadingMore = false
    /// 本地库里此刻的全部会话身份。
    private var savedKeys: Set<ConversationKey> = []
    /// 每次换一个集合（打开、改搜索词）就加一：旧集合晚到的答复据此丢弃。
    private var generation = 0

    public init(
        machine: Machine, sessions: any MachineSessionSource, store: any ConversationSaving,
        transfer: any MachineSessionTransfer, pageSize: Int = 30
    ) {
        self.machine = machine
        source = sessions
        self.store = store
        saver = ConversationSaver(store: store, transfer: transfer)
        self.pageSize = pageSize
    }

    /// 打开（或重新打开）：问机器要三个计数与第一页。机器离线时什么都不问——拉取要它来答。
    public func load() async {
        guard machine.online else {
            generation += 1
            rows = []
            counts = nil
            hasMore = false
            return
        }
        await refreshSaved()
        async let counted = try? source.counts(on: machine.fingerprint)
        await restart()
        counts = unreachable ? nil : await counted
    }

    /// 改搜索词：游标回到起点，关键词原样交给机器。
    public func search(_ keyword: String) async {
        self.keyword = keyword
        guard machine.online else { return }
        await restart()
    }

    /// 接着上一页往后翻。最后一页之后、或上一页还没回来时不再要。
    public func loadMore() async {
        guard machine.online, hasMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let current = generation
        guard let page = try? await source.sessions(on: machine.fingerprint, keyword: keyword, cursor: cursor, limit: pageSize),
              current == generation
        else { return }
        append(page)
    }

    /// 保存到手机：收进本地库并把转录拉全。成功后这一行读作已保存；失败则仍是未保存并带失败标记。
    public func save(_ key: ConversationKey) async {
        guard let index = rows.firstIndex(where: { $0.id == key }), !rows[index].isSaved, !rows[index].isSaving else { return }
        rows[index].isSaving = true
        rows[index].saveFailed = false
        let session = rows[index].session
        let failed: Bool
        do {
            try await saver.save(session, on: machine)
            failed = false
        } catch {
            failed = true
        }
        await refreshSaved()
        if let index = rows.firstIndex(where: { $0.id == key }) {
            rows[index].isSaving = false
            rows[index].saveFailed = failed
        }
    }

    /// 跟着本地库的变动更新每行的已保存状态，直到所在任务被取消。
    public func follow() async {
        for await _ in await store.changes() {
            await refreshSaved()
        }
    }

    private func restart() async {
        generation += 1
        let current = generation
        cursor = ""
        loadingMore = false
        do {
            let page = try await source.sessions(on: machine.fingerprint, keyword: keyword, cursor: "", limit: pageSize)
            guard current == generation else { return }
            rows = []
            unreachable = false
            updateRequired = false
            append(page)
        } catch is CancellationError {
            // 屏上的任务被取消（点进了一行）：不是没连上，已列出的照旧。
            return
        } catch {
            guard current == generation else { return }
            rows = []
            hasMore = false
            counts = nil
            unreachable = true
            updateRequired = FailureFact(presenting: error) == .updateRequired
        }
    }

    private func append(_ page: MachineSessionPage) {
        // 两页之间机器上新到的会话会把清单往后挤：已列过的不再列第二次。
        let listed = Set(rows.map(\.id))
        rows += page.sessions.map { session in
            let key = machine.key(of: session)
            return MachineSessionRow(session: session, key: key, isSaved: savedKeys.contains(key))
        }.filter { !listed.contains($0.id) }
        cursor = page.cursor
        hasMore = page.hasMore && !page.cursor.isEmpty
    }

    private func refreshSaved() async {
        guard let saved = try? await store.conversations() else { return }
        savedKeys = Set(saved.map(\.key))
        for index in rows.indices {
            rows[index].isSaved = savedKeys.contains(rows[index].key)
        }
    }
}
