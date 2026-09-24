import SwiftUI

@main
struct AgentreApp: App {
    @State private var environment: AppEnvironment? = AgentreApp.environment(for: ProcessInfo.processInfo.environment)

    var body: some Scene {
        WindowGroup {
            if let environment {
                AppRootView(environment: environment)
            }
        }
    }

    /// 应用的装配。作为单元测试的宿主启动时（进程环境里有 XCTest 的配置）不装配：宿主测试自己搭环境，
    /// 真实的钥匙串、本地库与默认的生产服务器都不该被测试进程碰到。
    static func environment(for process: [String: String]) -> AppEnvironment? {
        guard process["XCTestConfigurationFilePath"] == nil else { return nil }
        do {
            return try AppEnvironment(.live(), startSignedOut: startsSignedOut(process))
        } catch {
            // 库目录建不起来（沙盒不可写）时应用无从运转；这不是用户能处理的情形。
            fatalError("local store unavailable")
        }
    }

    /// 界面流程（XCUITest）经启动环境要求从登出状态起步。
    static func startsSignedOut(_ process: [String: String]) -> Bool {
        process["AGENTRE_START_SIGNED_OUT"] == "1"
    }
}
