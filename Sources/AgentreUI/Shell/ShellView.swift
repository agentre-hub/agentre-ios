import AgentreDesign
import SwiftUI

/// 三个顶层目的地：消息、机器、我。各页内容由应用装配层注入。
public struct ShellView<Messages: View, Machines: View, Me: View>: View {
    private let messages: Messages
    private let machines: Machines
    private let me: Me

    public init(@ViewBuilder messages: () -> Messages, @ViewBuilder machines: () -> Machines, @ViewBuilder me: () -> Me) {
        self.messages = messages()
        self.machines = machines()
        self.me = me()
    }

    public var body: some View {
        TabView {
            Tab {
                messages
            } label: {
                Label { Text("shell.tab.messages", tableName: "Shell", bundle: .module) } icon: { Image(systemName: "bubble.left.and.bubble.right") }
            }
            Tab {
                machines
            } label: {
                Label { Text("shell.tab.machines", tableName: "Shell", bundle: .module) } icon: { Image(systemName: "desktopcomputer") }
            }
            Tab {
                me
            } label: {
                Label { Text("shell.tab.me", tableName: "Shell", bundle: .module) } icon: { Image(systemName: "person.crop.circle") }
            }
        }
        .tint(.token(.primary))
    }
}
