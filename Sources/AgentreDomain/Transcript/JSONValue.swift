import Foundation

/// 一段已解析的 JSON。工具入参与 canonical 在线上是 JSON 字节，领域层在这里解开，
/// 判档与摘要都只看它的形状。
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// 解一段 JSON 字节；不是合法 JSON 时为 nil。
    public init?(json data: Data) {
        guard !data.isEmpty, let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        self.init(any: any)
    }

    /// 解一段 JSON 文本；不是合法 JSON 时为 nil。
    public init?(json text: String) {
        self.init(json: Data(text.utf8))
    }

    private init(any: Any) {
        switch any {
        case let number as NSNumber:
            // JSONSerialization 把布尔也装成 NSNumber，只能按底层类型分辨。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var int: Int? { number.flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil } }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? { object?[key] }

    /// 紧凑的 JSON 文本（键按字典序，结果稳定）。
    public var compactText: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if let int = int, Double(int) == value { return String(int) }
            return String(value)
        case .string(let value):
            let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data()
            let wrapped = String(decoding: data, as: UTF8.self)
            return String(wrapped.dropFirst().dropLast())
        case .array(let values):
            return "[" + values.map(\.compactText).joined(separator: ",") + "]"
        case .object(let values):
            let pairs = values.keys.sorted().map { key in "\(JSONValue.string(key).compactText):\(values[key]!.compactText)" }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
