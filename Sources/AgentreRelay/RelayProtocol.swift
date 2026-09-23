/// 本端所说的 wire 协议与中继约定。
public enum RelayProtocol {
    /// 本端的协议版本。主人是 wire.proto 的 `(agentre.wire.protocol_version)` 文件选项；
    /// SwiftProtobuf 不把文件选项编进产物，所以这里持一份，由 ProtocolVersionGuardTests
    /// 逐字对照 schema 钉住。兼容判据是逐字相等。
    public static let version = "0.3.0"
    /// 对端因协议版本不等拒绝握手的错误码（rpcerror.CodeProtocolVersion）。
    public static let errorCodeProtocolVersion: Int32 = -32006
    /// 会话没有在跑的那一轮可接（rpcerror.CodeRuntimeNoActiveTurn）：attach 一条已中断的会话时对端这样答。
    static let errorCodeNoActiveTurn: Int32 = -32010
    /// 账号信号那条保留通道（relay_svc.SignalChannelID）。号归服务端，本端只收不写。
    public static let signalChannelID = "~signal"
    /// 一页补齐拉多少条（与 wire 的 DefaultSessionPullLimit 同值）。
    static let pullLimit: Int32 = 200
}
