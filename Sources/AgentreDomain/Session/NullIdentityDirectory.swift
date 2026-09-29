import Foundation

/// 不查任何目录的占位实现：项目树报「从未取到过」，机器名一律查不到。
///
/// 给不关心身份（项目字形、机器名搜索）的调用点当默认值用，不是生产环境的取法——
/// 真正登录后的各屏都接的是 `WorkspaceIdentityDirectory`。
public struct NullIdentityDirectory: IdentityDirectory {
    public init() {}
    public func projects() async -> [WorkspaceProject]? { nil }
    public func machineName(fingerprint: String) async -> String? { nil }
}
