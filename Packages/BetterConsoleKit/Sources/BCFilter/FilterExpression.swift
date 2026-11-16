import BCModel
import Foundation

public enum FilterField: String, Codable, Sendable, CaseIterable {
    case process, pid, library, thread, subsystem, category, type, activity, message

    public var title: String {
        switch self {
        case .process: "Process"
        case .pid: "PID"
        case .library: "Library"
        case .thread: "Thread ID"
        case .subsystem: "Subsystem"
        case .category: "Category"
        case .type: "Type"
        case .activity: "Activity ID"
        case .message: "Message"
        }
    }

    public var allowedMatches: [MatchKind] {
        switch self {
        case .pid, .thread, .activity, .type: [.is]
        case .process, .library, .subsystem, .category, .message: MatchKind.allCases
        }
    }
}

public enum MatchKind: String, Codable, Sendable, CaseIterable {
    case contains, `is`, startsWith, regex

    public var title: String {
        switch self {
        case .contains: "contains"
        case .is: "is"
        case .startsWith: "starts with"
        case .regex: "matches regex"
        }
    }
}

public struct FilterCondition: Hashable, Codable, Sendable {
    public var field: FilterField
    public var match: MatchKind
    public var value: String
    public var isEnabled: Bool

    public init(field: FilterField, match: MatchKind, value: String, isEnabled: Bool = true) {
        self.field = field
        self.match = match
        self.value = value
        self.isEnabled = isEnabled
    }

    /// Type's fixed list (spec §5.1), lower-case as Console shows it.
    public static let typeValues = ["default", "info", "debug", "error", "fault"]

    /// This condition moved to `field`, kept usable: a match the field does not allow becomes
    /// `is` (the evaluator would drop the pair), and moving to Type turns the value into its
    /// fixed-list spelling, or "default" when it is not a Type.
    public func movedTo(_ field: FilterField) -> FilterCondition {
        var moved = self
        moved.field = field
        if !field.allowedMatches.contains(moved.match) { moved.match = .is }
        if field == .type {
            moved.value = Self.parseLevel(value).map { $0.rawValue.lowercased() } ?? "default"
        }
        return moved
    }

    private enum CodingKeys: String, CodingKey { case field, match, value, isEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(FilterField.self, forKey: .field)
        match = try c.decode(MatchKind.self, forKey: .match)
        value = try c.decode(String.self, forKey: .value)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(field, forKey: .field)
        try c.encode(match, forKey: .match)
        try c.encode(value, forKey: .value)
        if !isEnabled { try c.encode(false, forKey: .isEnabled) }
    }

    /// Why the value cannot be used, or nil when it is fine.
    public var valueProblem: String? {
        if match == .regex {
            do { _ = try NSRegularExpression(pattern: value, options: .caseInsensitive) } catch {
                return "Invalid regular expression: \(value)"
            }
            return nil
        }
        switch field {
        case .pid:
            return Self.parseDecimal(value, as: Int32.self) == nil ? "PID must be a whole number" : nil
        case .activity:
            return Self.parseDecimal(value, as: UInt64.self) == nil
                ? "Activity ID must be a whole number" : nil
        case .thread:
            return Self.parseThread(value) == nil
                ? "Thread ID must be decimal or hexadecimal (0x…)" : nil
        case .type:
            return Self.parseLevel(value) == nil
                ? "Type must be one of default, info, debug, error, fault" : nil
        default:
            return nil
        }
    }

    static func parseDecimal<T: FixedWidthInteger>(_ s: String, as: T.Type) -> T? {
        guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return T(s)
    }

    static func parseThread(_ s: String) -> UInt64? {
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            let digits = s.dropFirst(2)
            guard !digits.isEmpty else { return nil }
            return UInt64(digits, radix: 16)
        }
        return parseDecimal(s, as: UInt64.self)
    }

    static func parseLevel(_ s: String) -> LogLevel? {
        switch s.lowercased() {
        case "default": .default
        case "info": .info
        case "debug": .debug
        case "error": .error
        case "fault": .fault
        default: nil
        }
    }
}

public indirect enum FilterExpression: Hashable, Sendable, Codable {
    case condition(FilterCondition)
    case all([FilterExpression])
    case any([FilterExpression])
    case not(FilterExpression)

    private enum CodingKeys: String, CodingKey { case condition, all, any, not }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected exactly one of condition, all, any, not"))
        }
        switch key {
        case .condition: self = .condition(try c.decode(FilterCondition.self, forKey: .condition))
        case .all: self = .all(try c.decode([FilterExpression].self, forKey: .all))
        case .any: self = .any(try c.decode([FilterExpression].self, forKey: .any))
        case .not: self = .not(try c.decode(FilterExpression.self, forKey: .not))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .condition(let v): try c.encode(v, forKey: .condition)
        case .all(let v): try c.encode(v, forKey: .all)
        case .any(let v): try c.encode(v, forKey: .any)
        case .not(let v): try c.encode(v, forKey: .not)
        }
    }
}
