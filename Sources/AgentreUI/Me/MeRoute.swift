import Foundation

/// 「我」的二级页去处（规格「09 我」）：服务器地址、已授权设备、语言、外观。
/// 关于只显示版本号、不可点，不是一个去处。
///
/// 装配层把它按值 push 进 `Router.me`（`NavigationPath`）——任务 43 留下的规则：
/// 「我」的二级页须以值入栈，tab 栏才会随栈深退场。
public enum MeRoute: Hashable, Sendable {
    case server
    case devices
    case language
    case appearance
}
