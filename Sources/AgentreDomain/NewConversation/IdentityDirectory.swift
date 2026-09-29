import Foundation

/// 会话头像字形与副标题要问的两件事：项目树取到了没有、承载机器叫什么名字
/// （按会话的 `project_sync_id` 与承载机器指纹查）。
public protocol IdentityDirectory: Sendable {
    /// 账号的项目树；一次都没成功取到时为 `nil`——调用方据此把「不属于任何项目」与
    /// 「这一刻还不知道」分开（离线冷启动时头像字形的空白档，见 `IdentityGlyph.project`）。
    func projects() async -> [WorkspaceProject]?
    /// 承载机器此刻的呈现名；查不到时为 `nil`。
    func machineName(fingerprint: String) async -> String?
}
