import Foundation

/// 手机自有的会话记录（规格决策 8 / 16 / 17）：已保存会话的摘要与转录落在本机库里，
/// 冷启动与离线时照常可读。
///
/// 这里只声明读取与本机自己的操作；写入由认得 wire 的实现层提供（保存一条会话、
/// 让中继帧落库），表现层看不见实现。
public protocol ConversationStore: Sendable {
    /// 全部已保存的会话，最后活动新的在前。
    func conversations() async throws -> [SavedConversation]
    func conversation(_ key: ConversationKey) async throws -> SavedConversation?
    /// 一条会话已落库的全部帧，按 `seq` 升序。
    func transcript(_ key: ConversationKey) async throws -> [TranscriptFrame]
    /// 本机已落库的最大帧号；补齐从它之后接着拉。没存过这条会话时为 0。
    func latestSeq(_ key: ConversationKey) async throws -> Int64
    /// 把这条会话此刻的最后活动记为已读。
    func markRead(_ key: ConversationKey) async throws
    /// 删掉这条会话在本机的一切：摘要、帧、已读位。此后到达的帧不再落库。
    func delete(_ key: ConversationKey) async throws
    /// 退出登录：清空整个库，连同已读位与游标。
    func removeAll() async throws
    /// 库每变一次就吐一个信号（多次变动可能合并成一个）。每次调用给出一条独立的流。
    func changes() async -> AsyncStream<Void>
}

/// 本机在承载机上改成了的会话设定，照记进本地库那一行：清单下次刷新之前，这一行就是机器此刻的值；
/// 刷新回来的若与它不同，就是别的端此后又改过。不在库里时什么都不做。
public protocol ConversationSettingsRecording: ConversationStore {
    func recordModelTarget(_ key: ConversationKey, providerKey: String, modelKey: String) async throws
    func recordReasoningEffort(_ key: ConversationKey, effort: String) async throws
}
