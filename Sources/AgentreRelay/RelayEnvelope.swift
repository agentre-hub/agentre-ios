import Foundation

/// 中继通道信封被拒的原因。
public enum RelayEnvelopeError: Error, Equatable, Sendable {
    case emptyChannelID
    case channelIDTooLong
    case shorterThanHeader
    case invalidChannelIDLength
    case truncated
    case channelIDNotUTF8
}

/// 中继通道信封：2 字节大端通道 ID 长度 + 通道 ID（UTF-8）+ 载荷。
///
/// Go 侧 `pkg/wire/relayenvelope` 的移植：同一格式、同一组上限、同一套拒绝。中继上的
/// 每一帧都是别的设备发来的字节，几个宿主里最松的那份解析决定了实际下限。
/// 空载荷合法：它是「这条通道关了」的信号。
public enum RelayEnvelope {
    /// 长度前缀占的字节数。
    public static let headerBytes = 2
    /// 通道 ID 的字节上限。
    public static let maxChannelIDBytes = 128
    /// 信封头最多占多少；读上限里给它留的余量。
    public static let maxEnvelopeBytes = headerBytes + maxChannelIDBytes
    /// 一帧载荷的上限（Go 侧 wirelimits.MaxPayloadBytes）。
    public static let maxPayloadBytes = 10 << 20
    /// 物理连接的单帧读上限：套过信封的顶格载荷也要收得下。
    public static let readLimit = maxPayloadBytes + maxEnvelopeBytes

    public static func wrap(channelID: String, payload: Data) throws -> Data {
        let id = Data(channelID.utf8)
        guard !id.isEmpty else { throw RelayEnvelopeError.emptyChannelID }
        guard id.count <= maxChannelIDBytes else { throw RelayEnvelopeError.channelIDTooLong }
        var out = Data(capacity: headerBytes + id.count + payload.count)
        out.append(UInt8(id.count >> 8))
        out.append(UInt8(id.count & 0xFF))
        out.append(id)
        out.append(payload)
        return out
    }

    public static func unwrap(_ envelope: Data) throws -> (channelID: String, payload: Data) {
        let bytes = [UInt8](envelope)
        guard bytes.count >= headerBytes else { throw RelayEnvelopeError.shorterThanHeader }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, length <= maxChannelIDBytes else { throw RelayEnvelopeError.invalidChannelIDLength }
        let start = headerBytes + length
        guard bytes.count >= start else { throw RelayEnvelopeError.truncated }
        guard let id = String(validating: bytes[headerBytes..<start], as: UTF8.self) else {
            throw RelayEnvelopeError.channelIDNotUTF8
        }
        return (id, Data(bytes[start...]))
    }
}
