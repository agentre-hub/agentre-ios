import AgentreDesign
import AgentreDomain
import AgentreUI
import SwiftUI

/// 应用根：未登录是登录屏；登录态里是三标签骨架。显示偏好（语言、外观）两边都生效。
struct AppRootView: View {
    let environment: AppEnvironment

    var body: some View {
        RootView(session: environment.session) {
            LoginView(flow: environment.loginFlow)
        } shell: {
            SignedInRoot(environment: environment)
        }
        .displayPreferences(environment.me.preferences)
        .environment(\.isOffline, environment.connectivity.isOffline)
    }
}

/// 登录态的生命周期：出现时建好中继连接与各屏端口并开始跟随，离开（登出、刷新被拒）时拆掉。
private struct SignedInRoot: View {
    let environment: AppEnvironment
    @State private var services: SignedInServices?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let services {
                AppShell(services: services)
            } else {
                Rectangle().fill(.token(.bg)).ignoresSafeArea()
            }
        }
        .task {
            let started = environment.startServices()
            services = started
            // 挂到视图消失（登出）为止；之后拆掉这一套连接与跟随。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
            }
            services = nil
            await environment.tearDown(started)
        }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台：连接自己会重拨，这里补上此前跟随失败的会话。
            guard phase == .active, let services else { return }
            Task { await services.resume() }
        }
        .onChange(of: environment.connectivity.isOffline) { _, offline in
            // 网络回来了（飞行模式关掉、换了网）：同样补上离线期间跟随失败的会话。
            guard !offline, let services else { return }
            Task { await services.resume() }
        }
    }
}

/// 三个顶层目的地：消息、机器、我，各自一个导航栈。
private struct AppShell: View {
    let services: SignedInServices
    @Bindable private var router: Router

    init(services: SignedInServices) {
        self.services = services
        router = services.router
    }

    var body: some View {
        ShellView {
            NavigationStack(path: $router.messages) {
                MessagesView(model: services.messages) { key in router.messages.append(.conversation(key)) }
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                router.messages.append(.newConversation)
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .accessibilityLabel(Text("newconv.title", tableName: "NewConversation", bundle: AgentreUIResources.bundle))
                            }
                            .hitTarget()
                        }
                    }
                    .navigationDestination(for: MessagesRoute.self) { route in
                        MessagesDestination(services: services, route: route)
                    }
            }
        } machines: {
            NavigationStack(path: $router.machines) {
                MachinesView(model: services.machines) { machine in router.machines.append(.machine(machine.fingerprint)) }
                    .navigationDestination(for: MachinesRoute.self) { route in
                        MachinesDestination(services: services, route: route)
                    }
            }
        } me: {
            NavigationStack {
                MeView(model: services.me)
            }
        }
    }
}

/// 消息栈里的各屏：对话、新建对话（Agent 列表、按项目挑）与草稿。
private struct MessagesDestination: View {
    let services: SignedInServices
    let route: MessagesRoute

    var body: some View {
        switch route {
        case .conversation(let key):
            ConversationScreen(services: services, key: key) {
                services.router.messages.removeAll { $0 == route }
            }
        case .newConversation:
            NewConversationView(model: services.newConversation) { agent in
                services.router.messages.append(.draft(agent: agent.syncID, project: nil))
            } onBrowseProjects: {
                services.router.messages.append(.projects)
            }
            .task { await services.newConversation.load() }
        case .projects:
            NewConversationProjectList(model: services.newConversation) { project in
                services.router.messages.append(.project(project.syncID))
            }
        case .project(let syncID):
            if let project = services.project(syncID) {
                NewConversationProjectAgents(model: services.newConversation, project: project) { agent in
                    services.router.messages.append(.draft(agent: agent.syncID, project: syncID))
                }
            }
        case .draft:
            if let draft = services.draftModel(for: route) {
                DraftConversationView(model: draft) { key in
                    // 对话跑起来了：新建那几屏退场，换成这条对话。
                    services.router.messages = [.conversation(key)]
                }
            }
        }
    }
}

/// 机器栈里的各屏：机器详情，与从详情进入的已保存对话。
private struct MachinesDestination: View {
    let services: SignedInServices
    let route: MachinesRoute

    var body: some View {
        switch route {
        case .machine(let fingerprint):
            if let machine = services.machine(fingerprint) {
                MachineDetailView(model: services.detailModel(for: machine)) { key in
                    services.router.machines.append(.conversation(key))
                }
            }
        case .conversation(let key):
            ConversationScreen(services: services, key: key) {
                services.router.machines.removeAll { $0 == route }
            }
        }
    }
}
