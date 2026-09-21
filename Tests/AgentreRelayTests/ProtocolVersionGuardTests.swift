import AgentreRelay
import Foundation
import Testing

/// 协议版本的主人是 wire.proto 的文件选项；SwiftProtobuf 不把它编进产物，所以本端
/// 只能持一份常量。这条守卫让「子模块升了版本、常量忘了改」在这里变红，而不是在
/// 每一次握手里被对端拒绝。
struct ProtocolVersionGuardTests {
    static let wireProto = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Vendor/agentre/pkg/wire/proto/agentre/wire/wire.proto")

    @Test("RelayProtocol.version 与 wire.proto 的 (agentre.wire.protocol_version) 逐字相等")
    func versionMatchesSchema() throws {
        let schema = try String(contentsOf: Self.wireProto, encoding: .utf8)
        let pattern = /option\s+\(agentre\.wire\.protocol_version\)\s*=\s*"([^"]*)"\s*;/
        let matches = schema.matches(of: pattern)
        try #require(matches.count == 1, "wire.proto must declare the protocol_version option exactly once")
        #expect(RelayProtocol.version == String(matches[0].output.1))
    }
}
