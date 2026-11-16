import BCModel
import Foundation

public enum FilterField: String, Codable, Sendable, CaseIterable {
    case process, pid, library, thread, subsystem, category, type, activity, message
    case eventType, processPath, senderPath, timeOfDay, extra

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
        case .eventType: "Event type"
        case .processPath: "Process path"
        case .senderPath: "Sender path"
        case .timeOfDay: "Time of day"
        case .extra: "Extra data"
        }
    }

    /// The key in predicate text (ES §5.1). `timeOfDay` and `extra` are app-only; Extra data
    /// is written `extra["key"]`.
    public var predicateKey: String {
        switch self {
        case .process: "process"
        case .pid: "processIdentifier"
        case .library: "sender"
        case .thread: "threadIdentifier"
        case .subsystem: "subsystem"
        case .category: "category"
        case .type: "messageType"
        case .activity: "activityIdentifier"
        case .message: "eventMessage"
        case .eventType: "eventType"
        case .processPath: "processImagePath"
        case .senderPath: "senderImagePath"
        case .timeOfDay: "timeOfDay"
        case .extra: "extra"
        }
    }

    /// ES §5.2.
    public var allowedMatches: [MatchKind] {
        switch self {
        case .process, .library, .subsystem, .category, .message, .eventType, .processPath,
             .senderPath, .extra:
            [.is, .contains, .startsWith, .endsWith, .regex]
        case .pid, .thread, .activity, .type:
            [.is, .regex, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual]
        case .timeOfDay:
            [.between]
        }
    }
}

public enum MatchKind: String, Codable, Sendable, CaseIterable {
    case contains, `is`, startsWith, endsWith, regex
    case lessThan, lessOrEqual, greaterThan, greaterOrEqual, between

    public var title: String {
        switch self {
        case .contains: "contains"
        case .is: "is"
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        case .regex: "matches regex (whole value)"
        case .lessThan: "<"
        case .lessOrEqual: "≤"
        case .greaterThan: ">"
        case .greaterOrEqual: "≥"
        case .between: "between"
        }
    }

    /// The title as shown next to `field`: Type reads "at most" / "at least".
    public func title(for field: FilterField) -> String {
        switch (field, self) {
        case (.type, .lessOrEqual): "at most"
        case (.type, .greaterOrEqual): "at least"
        default: title
        }
    }

    var isComparison: Bool {
        switch self {
        case .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual: true
        default: false
        }
    }
}

public struct FilterCondition: Hashable, Codable, Sendable {
    public var field: FilterField
    public var match: MatchKind
    public var value: String
    /// The key looked up in `extra` (Extra data only).
    public var key: String?
    /// The end of a `between` range (Time of day only).
    public var upperValue: String?
    public var isEnabled: Bool

    public init(
        field: FilterField, match: MatchKind, value: String, key: String? = nil,
        upperValue: String? = nil, isEnabled: Bool = true
    ) {
        self.field = field
        self.match = match
        self.value = value
        self.key = key
        self.upperValue = upperValue
        self.isEnabled = isEnabled
    }

    /// Type's fixed list (spec §5.1), lower-case as Console shows it, in `log`'s order.
    public static let typeValues = ["default", "info", "debug", "error", "fault"]

    /// This condition moved to `field`, kept usable: a match the field does not allow becomes
    /// `is` (`between` for Time of day), moving to Type turns a non-regex value into its
    /// fixed-list spelling ("default" when it is not a Type), moving to Time of day keeps
    /// times that parse and otherwise covers the whole day, and moving to Extra data starts
    /// with an empty key (a value problem until one is entered). Leaving Extra data drops the
    /// key; leaving Time of day drops the end.
    public func movedTo(_ field: FilterField) -> FilterCondition {
        var moved = self
        moved.field = field
        if !field.allowedMatches.contains(moved.match) {
            moved.match = field == .timeOfDay ? .between : .is
        }
        switch field {
        case .type where moved.match != .regex:
            moved.value = Self.parseLevel(value).map { $0.rawValue.lowercased() } ?? "default"
        case .timeOfDay:
            if Self.parseTime(value) == nil { moved.value = "00:00" }
            if upperValue.flatMap(Self.parseTime) == nil { moved.upperValue = "23:59" }
        case .extra:
            moved.key = key ?? ""
        default:
            break
        }
        if field != .extra { moved.key = nil }
        if field != .timeOfDay { moved.upperValue = nil }
        return moved
    }

    private enum CodingKeys: String, CodingKey { case field, match, value, key, upperValue, isEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(FilterField.self, forKey: .field)
        match = try c.decode(MatchKind.self, forKey: .match)
        value = try c.decode(String.self, forKey: .value)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        upperValue = try c.decodeIfPresent(String.self, forKey: .upperValue)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(field, forKey: .field)
        try c.encode(match, forKey: .match)
        try c.encode(value, forKey: .value)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encodeIfPresent(upperValue, forKey: .upperValue)
        if !isEnabled { try c.encode(false, forKey: .isEnabled) }
    }

    /// Why the value cannot be used, or nil when it is fine.
    public var valueProblem: String? {
        if field == .extra, key?.isEmpty ?? true { return "Enter a key" }
        if match == .regex {
            return Self.wholeValueRegex(value) == nil ? "Invalid regular expression: \(value)" : nil
        }
        switch field {
        case .pid:
            return Self.parseInteger(value, as: Int32.self) == nil
                ? "PID must be a whole number, decimal or hexadecimal (0x…)" : nil
        case .activity:
            return Self.parseInteger(value, as: UInt64.self) == nil
                ? "Activity ID must be a whole number, decimal or hexadecimal (0x…)" : nil
        case .thread:
            return Self.parseInteger(value, as: UInt64.self) == nil
                ? "Thread ID must be decimal or hexadecimal (0x…)" : nil
        case .type:
            return Self.parseLevel(value) == nil
                ? "Type must be one of default, info, debug, error, fault" : nil
        case .timeOfDay:
            if Self.parseTime(value) == nil { return "Use HH:mm or HH:mm:ss" }
            guard let upperValue, !upperValue.isEmpty else { return "Enter an end time" }
            return Self.parseTime(upperValue) == nil ? "Use HH:mm or HH:mm:ss" : nil
        default:
            return nil
        }
    }

    /// The pattern compiled to match only a whole value, as MATCHES does in `log` and
    /// NSPredicate (alternatives are tried until one covers the value). The pattern must
    /// compile on its own first, so the wrapper can't balance an invalid one (`a)(?:b`).
    ///
    /// The wrapper's `)\z` must stay outside the pattern: a pattern ending inside `\Q…` gets
    /// its `\E`, and one ending in an extended-mode `# comment` (`(?x)`), which would swallow
    /// `)\z`, gets a line break before it. The line break is only tried when the plain
    /// wrapper doesn't compile, which is the only way a comment can reach it (the pattern is
    /// balanced on its own); in extended mode it is ignored as space.
    static func wholeValueRegex(_ pattern: String) -> NSRegularExpression? {
        guard (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)) != nil
        else { return nil }
        let body = pattern + (endsInsideQuote(pattern) ? #"\E"# : "")
        return (try? NSRegularExpression(pattern: #"\A(?:"# + body + #")\z"#, options: .caseInsensitive))
            ?? (try? NSRegularExpression(pattern: #"\A(?:"# + body + "\n" + #")\z"#, options: .caseInsensitive))
    }

    /// Whether a `\Q` quote is still open at the end of `pattern` (ICU quotes to the end).
    static func endsInsideQuote(_ pattern: String) -> Bool {
        let scalars = Array(pattern.unicodeScalars)
        var inQuote = false
        var i = 0
        while i < scalars.count {
            let isEscape = scalars[i] == "\\" && i + 1 < scalars.count
            if inQuote {
                if isEscape, scalars[i + 1] == "E" { inQuote = false; i += 2 } else { i += 1 }
            } else if isEscape {
                if scalars[i + 1] == "Q" { inQuote = true }
                i += 2
            } else {
                i += 1
            }
        }
        return inQuote
    }

    static func parseDecimal<T: FixedWidthInteger>(_ s: String, as: T.Type) -> T? {
        guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return T(s)
    }

    /// Decimal, or hexadecimal after `0x` (as `log` accepts for PID, Thread ID and Activity
    /// ID).
    static func parseInteger<T: FixedWidthInteger>(_ s: String, as: T.Type) -> T? {
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            let digits = s.dropFirst(2)
            guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }
            return T(digits, radix: 16)
        }
        return parseDecimal(s, as: T.self)
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

    /// A wall-clock time `H:mm`, `HH:mm` or `HH:mm:ss`: its start in seconds since midnight,
    /// and its length (60 for a minute, 1 for a second), so an end time can include all of it
    /// (ES §13.5).
    static func parseTime(_ s: String) -> (start: Int, length: Int)? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              (1...2).contains(parts[0].count), parts.dropFirst().allSatisfy({ $0.count == 2 }),
              let h = parseDecimal(String(parts[0]), as: Int.self), h < 24,
              let m = parseDecimal(String(parts[1]), as: Int.self), m < 60
        else { return nil }
        if parts.count == 2 { return (h * 3600 + m * 60, 60) }
        guard let sec = parseDecimal(String(parts[2]), as: Int.self), sec < 60 else { return nil }
        return (h * 3600 + m * 60 + sec, 1)
    }
}

public indirect enum FilterExpression: Hashable, Sendable, Codable {
    case condition(FilterCondition)
    case all([FilterExpression])
    case any([FilterExpression])
    case not(FilterExpression)
    /// Matches when the saved filter with this id matches (resolved at compile time).
    case link(UUID)

    private enum CodingKeys: String, CodingKey { case condition, all, any, not, link }

    private struct LinkReference: Codable { var id: UUID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected exactly one of condition, all, any, not, link"))
        }
        switch key {
        case .condition: self = .condition(try c.decode(FilterCondition.self, forKey: .condition))
        case .all: self = .all(try c.decode([FilterExpression].self, forKey: .all))
        case .any: self = .any(try c.decode([FilterExpression].self, forKey: .any))
        case .not: self = .not(try c.decode(FilterExpression.self, forKey: .not))
        case .link: self = .link(try c.decode(LinkReference.self, forKey: .link).id)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .condition(let v): try c.encode(v, forKey: .condition)
        case .all(let v): try c.encode(v, forKey: .all)
        case .any(let v): try c.encode(v, forKey: .any)
        case .not(let v): try c.encode(v, forKey: .not)
        case .link(let id): try c.encode(LinkReference(id: id), forKey: .link)
        }
    }
}
