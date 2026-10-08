import SwiftUI

public extension EnvironmentValues {
    /// 这台设备此刻没有网络（飞行模式、无网）。本地库照常可读；可发的动作不可用，
    /// 屏上如实说明是离线，而不是呈现为加载失败（规格「失败与恢复」）。由装配层按系统网络路径注入。
    @Entry var isOffline = false
}
