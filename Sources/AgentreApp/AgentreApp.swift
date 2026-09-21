import SwiftUI

@main
struct AgentreApp: App {
    @State private var environment: AppEnvironment = {
        do {
            return try AppEnvironment(.live())
        } catch {
            // 库目录建不起来（沙盒不可写）时应用无从运转；这不是用户能处理的情形。
            fatalError("local store unavailable")
        }
    }()

    var body: some Scene {
        WindowGroup {
            AppRootView(environment: environment)
        }
    }
}
