import AgentreDesign
import AgentreDomain
import AgentreUI
import SwiftUI

/// 应用根：未登录是登录屏；登录态里是三个顶层页的外壳。显示偏好（语言、外观）两边都生效。
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

/// 三个顶层目的地：消息、机器、我，各自一个导航栈；新建对话是盖在上面、自带栈的模态。
private struct AppShell: View {
    let services: SignedInServices
    @Bindable private var router: Router

    init(services: SignedInServices) {
        self.services = services
        router = services.router
    }

    var body: some View {
        ShellView(selection: $router.tab, showsTabBar: router.showsTabBar) {
            NavigationStack(path: $router.messages) {
                MessagesView(model: services.messages) { key in router.messages.append(.conversation(key)) }
                    .topLevelHeader(Text("messages.title", tableName: "Messages", bundle: AgentreUIResources.bundle)) {
                        ChromeIconButton(.squarePen, label: Text("newconv.title", tableName: "NewConversation", bundle: AgentreUIResources.bundle)) {
                            router.newConversation = []
                        }
                    }
                    .navigationDestination(for: MessagesRoute.self) { route in
                        MessagesDestination(services: services, route: route)
                    }
            }
        } machines: {
            NavigationStack(path: $router.machines) {
                MachinesView(model: services.machines) { machine in router.machines.append(.machine(machine.fingerprint)) }
                    .topLevelHeader(Text("machines.title", tableName: "Machines", bundle: AgentreUIResources.bundle))
                    .navigationDestination(for: MachinesRoute.self) { route in
                        MachinesDestination(services: services, route: route)
                    }
            }
        } me: {
            NavigationStack(path: $router.me) {
                MeView(model: services.me)
                    .topLevelHeader(Text("me.title", tableName: "Me", bundle: AgentreUIResources.bundle))
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { router.newConversation != nil },
            set: { presented in if !presented { router.newConversation = nil } }
        )) {
            NewConversationFlow(services: services)
        }
    }
}

/// 消息栈里的各屏：对话。
private struct MessagesDestination: View {
    let services: SignedInServices
    let route: MessagesRoute

    var body: some View {
        switch route {
        case .conversation(let key):
            ConversationScreen(services: services, key: key) {
                services.router.messages.removeAll { $0 == route }
            }
        }
    }
}

/// 新建对话模态：根屏是 Agent 列表（左上「取消」），其后是按项目挑与草稿。草稿的第一条发出去即收起模态，
/// 在消息页的栈上打开这条对话。
private struct NewConversationFlow: View {
    let services: SignedInServices
    @Bindable private var router: Router

    init(services: SignedInServices) {
        self.services = services
        router = services.router
    }

    var body: some View {
        NavigationStack(path: Binding(
            get: { router.newConversation ?? [] },
            // 收起的动画里栈还会回写一次：模态已关就不再打开它。
            set: { path in if router.newConversation != nil { router.newConversation = path } }
        )) {
            NewConversationView(model: services.newConversation) { agent in
                router.newConversation?.append(.draft(agent: agent.syncID, project: nil))
            } onBrowseProjects: {
                router.newConversation?.append(.projects)
            }
            .modalNavigationBar(title: Text("shell.newConversation", tableName: "Shell", bundle: AgentreUIResources.bundle)) {
                router.newConversation = nil
            }
            .task { await services.newConversation.load() }
            .navigationDestination(for: NewConversationRoute.self) { route in
                NewConversationDestination(services: services, route: route)
            }
        }
    }
}

/// 新建对话模态栈里的各屏：按项目挑（项目列表、项目下的 Agent）与草稿。
private struct NewConversationDestination: View {
    let services: SignedInServices
    let route: NewConversationRoute

    var body: some View {
        switch route {
        case .projects:
            NewConversationProjectList(model: services.newConversation) { project in
                services.router.newConversation?.append(.project(project.syncID))
            }
            .compactNavigationBar(title: Text("newconv.projects", tableName: "NewConversation", bundle: AgentreUIResources.bundle))
        case .project(let syncID):
            if let project = services.project(syncID) {
                NewConversationProjectAgents(model: services.newConversation, project: project) { agent in
                    services.router.newConversation?.append(.draft(agent: agent.syncID, project: syncID))
                }
                .compactNavigationBar(title: Text(verbatim: project.name))
            }
        case .draft:
            if let draft = services.draftModel(for: route) {
                DraftConversationView(model: draft) { key in
                    services.router.open(started: key)
                }
                .compactNavigationBar(title: Text(verbatim: draft.agent.name))
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
                .compactNavigationBar(title: Text(verbatim: machine.name), subtitle: machine.reportedSummary.map { Text(verbatim: $0) })
            }
        case .conversation(let key):
            ConversationScreen(services: services, key: key) {
                services.router.machines.removeAll { $0 == route }
            }
        }
    }
}
