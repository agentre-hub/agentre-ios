import AgentreRelay
import Foundation
import Testing

/// 与 Go 侧 pkg/wire/relayenvelope 同一格式、同一套上限与拒绝。
struct RelayEnvelopeTests {
    @Test("套上信封：2 字节大端长度 + UTF-8 通道 ID + 载荷，拆开得到原样")
    func roundTrip() throws {
        let envelope = try RelayEnvelope.wrap(channelID: "c1", payload: Data([0xAA, 0xBB]))
        #expect(envelope == Data([0x00, 0x02, 0x63, 0x31, 0xAA, 0xBB]))
        let (id, payload) = try RelayEnvelope.unwrap(envelope)
        #expect(id == "c1")
        #expect(payload == Data([0xAA, 0xBB]))
    }

    @Test("空载荷合法：它是「这条通道关了」的信号")
    func emptyPayload() throws {
        let (id, payload) = try RelayEnvelope.unwrap(try RelayEnvelope.wrap(channelID: "~signal", payload: Data()))
        #expect(id == "~signal")
        #expect(payload.isEmpty)
    }

    @Test("上限与 Go 同值：通道 ID 128 字节，读上限 = 载荷上限 10 MiB + 信封头 130")
    func limits() {
        #expect(RelayEnvelope.headerBytes == 2)
        #expect(RelayEnvelope.maxChannelIDBytes == 128)
        #expect(RelayEnvelope.maxEnvelopeBytes == 130)
        #expect(RelayEnvelope.maxPayloadBytes == 10 << 20)
        #expect(RelayEnvelope.readLimit == (10 << 20) + 130)
    }

    @Test("套信封拒绝空通道 ID 与超长通道 ID；128 字节恰好可以")
    func wrapRejections() throws {
        #expect(throws: RelayEnvelopeError.emptyChannelID) {
            try RelayEnvelope.wrap(channelID: "", payload: Data())
        }
        #expect(throws: RelayEnvelopeError.channelIDTooLong) {
            try RelayEnvelope.wrap(channelID: String(repeating: "a", count: 129), payload: Data())
        }
        // 按字节计，不按字符：43 个三字节汉字 = 129 字节。
        #expect(throws: RelayEnvelopeError.channelIDTooLong) {
            try RelayEnvelope.wrap(channelID: String(repeating: "中", count: 43), payload: Data())
        }
        let max = String(repeating: "a", count: 128)
        #expect(try RelayEnvelope.unwrap(RelayEnvelope.wrap(channelID: max, payload: Data())).channelID == max)
    }

    @Test("拆信封拒绝：短于长度前缀、长度 0、长度超上限、载荷前截断、非 UTF-8")
    func unwrapRejections() {
        #expect(throws: RelayEnvelopeError.shorterThanHeader) { try RelayEnvelope.unwrap(Data([0x00])) }
        #expect(throws: RelayEnvelopeError.invalidChannelIDLength) { try RelayEnvelope.unwrap(Data([0x00, 0x00, 0x01])) }
        #expect(throws: RelayEnvelopeError.invalidChannelIDLength) {
            try RelayEnvelope.unwrap(Data([0x00, 129]) + Data(repeating: 0x61, count: 129))
        }
        #expect(throws: RelayEnvelopeError.truncated) { try RelayEnvelope.unwrap(Data([0x00, 0x03, 0x61])) }
        #expect(throws: RelayEnvelopeError.channelIDNotUTF8) { try RelayEnvelope.unwrap(Data([0x00, 0x01, 0xFF])) }
    }

    @Test("拆开时的载荷可以为空，也可以任意长")
    func unwrapPayloadBoundaries() throws {
        #expect(try RelayEnvelope.unwrap(Data([0x00, 0x01, 0x61])).payload.isEmpty)
        let big = Data(repeating: 7, count: 70_000)
        #expect(try RelayEnvelope.unwrap(Data([0x00, 0x01, 0x61]) + big).payload == big)
    }
}
