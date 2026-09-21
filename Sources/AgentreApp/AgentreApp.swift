import AgentreDesign
import AgentreUI
import SwiftUI

@main
struct AgentreApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView(session: environment.session) {
                LoginView(flow: environment.loginFlow)
            } shell: {
                // 三个目的地的内容由后续任务各自接入；这里先是空白页。
                ShellView {
                    EmptyDestination()
                } machines: {
                    EmptyDestination()
                } me: {
                    EmptyDestination()
                }
            }
        }
    }
}

private struct EmptyDestination: View {
    var body: some View {
        Rectangle()
            .fill(.token(.bg))
            .ignoresSafeArea(edges: .top)
    }
}
