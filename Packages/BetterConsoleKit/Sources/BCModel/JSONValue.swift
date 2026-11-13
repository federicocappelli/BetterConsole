/// A verbatim JSON value, used to keep source fields that have no typed home in `LogEntry`.
public enum JSONValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Values nested inside this one (object members and array elements, recursively).
    var nestedNodeCount: Int {
        switch self {
        case .string, .number, .bool, .null: 0
        case .array(let a): a.reduce(a.count) { $0 + $1.nestedNodeCount }
        case .object(let o): o.values.reduce(o.count) { $0 + $1.nestedNodeCount }
        }
    }

    /// Approximate size of the value when serialized as JSON, in UTF-8 bytes.
    var estimatedSerializedLength: Int {
        switch self {
        case .string(let s): s.utf8.count + 2
        case .number: 8
        case .bool(let b): b ? 4 : 5
        case .null: 4
        case .array(let a): a.reduce(2) { $0 + $1.estimatedSerializedLength + 1 }
        case .object(let o): o.reduce(2) { $0 + $1.key.utf8.count + 3 + $1.value.estimatedSerializedLength + 1 }
        }
    }
}
