import SwiftUI
import UIKit

/// 稿子用到的 lucide 图标，原始值是 lucide 名，也是资源名。全部按模板着色：颜色由 `.foregroundStyle(.token(_:))` 给。
public enum AgentreIcon: String, CaseIterable, Sendable {
    case arrowDown = "arrow-down"
    case arrowUp = "arrow-up"
    case brain
    case check
    case chevronDown = "chevron-down"
    case chevronLeft = "chevron-left"
    case chevronRight = "chevron-right"
    case chevronUp = "chevron-up"
    case chevronsUp = "chevrons-up"
    case cpu
    case ellipsis
    case externalLink = "external-link"
    case filePen = "file-pen"
    case fileSearch = "file-search"
    case fileText = "file-text"
    case folder
    case folderTree = "folder-tree"
    case gauge
    case github
    case globe
    case info
    case languages
    case listFilter = "list-filter"
    case listPlus = "list-plus"
    case logOut = "log-out"
    case messageCircle = "message-circle"
    case messageCircleQuestionMark = "message-circle-question-mark"
    case monitor
    case plugZap = "plug-zap"
    case plus
    case search
    case server
    case shieldAlert = "shield-alert"
    case shieldCheck = "shield-check"
    case smartphone
    case sparkles
    case square
    case squarePen = "square-pen"
    case sunMoon = "sun-moon"
    case terminal
    case trash2 = "trash-2"
    case user
}

extension Image {
    /// 界面取图标的入口：lucide 线性图标，24pt 画布，随 `.resizable()` / `.frame` 缩放。
    public init(_ icon: AgentreIcon) {
        self.init(icon.rawValue, bundle: .module)
    }
}

extension UIImage {
    /// 给 UIKit 视图用的同一个图标。
    public convenience init?(_ icon: AgentreIcon) {
        self.init(named: icon.rawValue, in: .module, with: nil)
    }
}
