import Foundation
@testable import AgentreUI
import Testing

/// 稿子上写定的简体中文文案（规格「逐屏视觉契约」：文案以稿子为准）。按 zh-Hans 的字符串目录逐条核对，
/// 不经界面——界面测试按当前语言取值，看不出目录里写的是不是稿子那一句。
struct DesignCopyTests {
    @Test("简体中文文案与稿子一致", arguments: [
        ("composer.message", "Composer", "接着说…"),
        ("machines.detail.count.total", "Machines", "会话总数"),
        ("machines.lastSeen %@", "Machines", "最后在线 %@"),
    ])
    func matchesTheDesign(key: String, table: String, expected: String) throws {
        let path = try #require(AgentreUIResources.bundle.path(forResource: "zh-Hans", ofType: "lproj"))
        let zh = try #require(Bundle(path: path))
        #expect(zh.localizedString(forKey: key, value: "⟨missing⟩", table: table) == expected)
    }
}
