import Foundation

// 更多面板取值的显示形（规格「逐屏视觉契约·04 更多面板」）：权限模式与思考档位的已知档位换成
// 人话，执行端报出表外的值时原样等宽；上下文行的「已用k/上限k」摘要。

/// 权限档位：已知的四档由界面换成人话；执行端报出表外的值时原样等宽（不假装认得）。
public enum PermissionModeDisplay: Sendable, Equatable {
    case standard(PermissionMode)
    case raw(String)

    public enum PermissionMode: String, Sendable, CaseIterable, Equatable {
        case `default`, acceptEdits, plan, bypassPermissions
    }

    public init(_ mode: String) {
        if let known = PermissionMode(rawValue: mode) {
            self = .standard(known)
        } else {
            self = .raw(mode)
        }
    }
}

/// 思考档位：低 / 中 / 高由界面换成人话；执行端报出的更高档（如 xhigh、max）原样等宽。
public enum ReasoningEffortDisplay: Sendable, Equatable {
    case standard(ReasoningLevel)
    case raw(String)

    public enum ReasoningLevel: String, Sendable, CaseIterable, Equatable {
        case low, medium, high
    }

    public init(_ effort: String) {
        if let known = ReasoningLevel(rawValue: effort) {
            self = .standard(known)
        } else {
            self = .raw(effort)
        }
    }
}

extension ContextUsage {
    /// 更多面板「上下文」行的取值：「已用k/上限k」，四舍五入到千（规格「04 更多面板」）。
    /// 与上下文浮层给绝对值不同——那里读的是原始数字，这里是面板行的紧凑摘要。
    public var compactSummary: String { "\(Self.thousands(used))k/\(Self.thousands(max))k" }

    private static func thousands(_ n: Int) -> Int { Int((Double(Swift.max(0, n)) / 1000).rounded()) }
}
