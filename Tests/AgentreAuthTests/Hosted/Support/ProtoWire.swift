import Foundation

// 宿主测试里的伪机器按字节说 wire 协议。测试包从宿主 App 解析符号，App 没用到的 AgentreWire
// 生成类型会被裁掉、链接不上，所以这里手写最小的 protobuf 编解码：字段号逐一取自
// Vendor/agentre/pkg/wire/proto/agentre/wire/wire.proto。它同时是 App 一侧编解码的一份独立对照。

/// 按字段号追加的一条 protobuf 消息。
struct Proto {
    private(set) var data = Data()

    init() {}

    init(_ build: (inout Proto) -> Void) {
        build(&self)
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        appendVarint(value)
    }

    mutating func int(_ field: Int, _ value: Int64) {
        varint(field, UInt64(bitPattern: value))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        varint(field, value ? 1 : 0)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        key(field, wireType: 2)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ value: Proto) {
        bytes(field, value.data)
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        appendVarint(UInt64(field) << 3 | wireType)
    }

    private mutating func appendVarint(_ value: UInt64) {
        var rest = value
        while rest >= 0x80 {
            data.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        data.append(UInt8(rest))
    }
}

/// 解开的一条 protobuf 消息：字段号 → 出现过的值。
struct ProtoFields {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed
    }

    private(set) var values: [Int: [Value]] = [:]

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while index < bytes.count, let key = readVarint() {
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = readVarint() else { return }
                values[field, default: []].append(.varint(value))
            case 1:
                index += 8
                values[field, default: []].append(.fixed)
            case 2:
                guard let length = readVarint(), index + Int(length) <= bytes.count else { return }
                values[field, default: []].append(.bytes(Data(bytes[index..<index + Int(length)])))
                index += Int(length)
            case 5:
                index += 4
                values[field, default: []].append(.fixed)
            default:
                return
            }
        }
    }

    func varint(_ field: Int) -> UInt64 {
        for value in values[field] ?? [] { if case .varint(let v) = value { return v } }
        return 0
    }

    func int(_ field: Int) -> Int64 { Int64(bitPattern: varint(field)) }

    func bool(_ field: Int) -> Bool { varint(field) != 0 }

    func bytes(_ field: Int) -> Data? {
        for value in values[field] ?? [] { if case .bytes(let d) = value { return d } }
        return nil
    }

    func string(_ field: Int) -> String {
        bytes(field).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func message(_ field: Int) -> ProtoFields? {
        bytes(field).map(ProtoFields.init)
    }

    func has(_ field: Int) -> Bool { values[field] != nil }
}

/// 伪机器用到的方法号（RpcMethod）。
enum WireMethod {
    static let authAccount: UInt32 = 1
    static let sessionList: UInt32 = 2
    static let sessionAttach: UInt32 = 3
    static let sessionPull: UInt32 = 4
    static let runtimeCapabilities: UInt32 = 8
    static let runtimeSteer: UInt32 = 9
    static let runtimeDrainPending: UInt32 = 11
    static let runtimeSetPermissionMode: UInt32 = 14
    static let runtimeSubmitToolPermission: UInt32 = 16
    static let runtimeRun: UInt32 = 17
    static let sessionCounts: UInt32 = 59
}

/// 伪机器要造的几种通知（RpcNotification）。
enum WireNotification {
    /// runtime.event：`event` 是 RuntimeEventNotification 里 oneof 的那一格。
    static func runtimeEvent(_ conversationID: String, seq: Int64, _ field: Int, _ event: Proto) -> Proto {
        Proto { n in
            n.message(1, Proto { e in
                e.string(1, conversationID)
                if seq > 0 { e.int(2, seq) }
                e.message(field, event)
            })
        }
    }

    static func userMessage(_ conversationID: String, seq: Int64, _ text: String) -> Proto {
        runtimeEvent(conversationID, seq: seq, 13, Proto { $0.string(1, text) })
    }

    static func textDelta(_ conversationID: String, seq: Int64, _ text: String) -> Proto {
        runtimeEvent(conversationID, seq: seq, 3, Proto { $0.string(1, text) })
    }

    static func permissionRequest(_ conversationID: String, seq: Int64, requestID: String, tool: String, input: String) -> Proto {
        runtimeEvent(conversationID, seq: seq, 19, Proto { r in
            r.string(1, requestID)
            r.string(2, "call-\(requestID)")
            r.string(3, tool)
            r.bytes(4, Data(input.utf8))
        })
    }

    /// 执行端报的当前权限档位（permission_mode_changed）。
    static func permissionModeChanged(_ conversationID: String, seq: Int64, _ mode: String) -> Proto {
        runtimeEvent(conversationID, seq: seq, 6, Proto { $0.string(1, mode) })
    }

    static func turnStarted(_ conversationID: String) -> Proto {
        Proto { $0.message(8, Proto { $0.string(1, conversationID) }) }
    }

    static func turnDone(_ conversationID: String) -> Proto {
        Proto { $0.message(2, Proto { $0.string(1, conversationID) }) }
    }

    static func steerConsumed(_ conversationID: String, queuedID: String, text: String) -> Proto {
        runtimeEvent(conversationID, seq: 0, 16, Proto { s in
            s.message(1, Proto { c in
                c.string(1, queuedID)
                c.string(2, text)
            })
        })
    }
}

/// 落库与比对用的帧字节。
enum WireFrames {
    /// 一帧正文增量（RpcNotification 的字节）。
    static func text(_ conversationID: String, _ text: String) throws -> Data {
        WireNotification.textDelta(conversationID, seq: 0, text).data
    }

    /// 一帧正文增量里的字；不是正文增量时为空。
    static func textOf(_ payload: Data) throws -> String {
        ProtoFields(payload).message(1)?.message(3)?.string(1) ?? ""
    }
}
