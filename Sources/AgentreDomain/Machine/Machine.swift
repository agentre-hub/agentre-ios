import Foundation

/// 账号名下一台承载会话的机器（桌面端或 agentred），取自服务端的设备名册。
public struct Machine: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let fingerprint: String
    /// 呈现用的名字：用户起过备注名就用它，否则是机器自报的主机名。
    public let name: String
    public let kind: String
    public let platform: String
    public let version: String
    /// 中继在线态：此刻能不能经中继问它要东西。
    public let online: Bool
    /// 最后在线的时刻（Unix 毫秒）；0 表示服务端没记。
    public let lastSeenAt: Int64

    public init(
        id: Int64, fingerprint: String, name: String, kind: String = "", platform: String = "", version: String = "",
        online: Bool, lastSeenAt: Int64 = 0
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.name = name
        self.kind = kind
        self.platform = platform
        self.version = version
        self.online = online
        self.lastSeenAt = lastSeenAt
    }

    /// 机器上的一条会话在本地库里的身份：清单回显了发起端就以它为主，否则就是这台机器。
    public func key(of session: MachineSession) -> ConversationKey {
        ConversationKey(
            machineFingerprint: session.peerFingerprint.isEmpty ? fingerprint : session.peerFingerprint,
            conversationID: session.conversationID
        )
    }
}

/// 机器名册（REST）。
public protocol MachineRoster: Sendable {
    /// 账号名下承载会话的机器，带此刻的在线态。
    func machines() async throws -> [Machine]
}
