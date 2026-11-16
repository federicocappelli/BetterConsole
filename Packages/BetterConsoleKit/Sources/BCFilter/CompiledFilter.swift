import BCModel
import Foundation

/// A filter expression compiled once for fast per-entry evaluation. Disabled and invalid
/// conditions are dropped as if absent; groups left empty impose no constraint.
public struct CompiledFilter: Sendable {
    private let root: Node?
    /// Whether any kept condition is a regex. Regex evaluation can take very long per entry
    /// (catastrophic backtracking), so long-running callers check for cancellation per entry.
    public let containsRegex: Bool

    /// `resolve` returns a saved filter's current expression. A link compiles that expression
    /// in place; a link that doesn't resolve, or that is already on the path being resolved
    /// (a loop), is dropped like an invalid condition.
    public init(
        _ expression: FilterExpression?, resolve: (UUID) -> FilterExpression? = { _ in nil }
    ) {
        root = withoutActuallyEscaping(resolve) { resolve in
            var compiler = Compiler(resolve: resolve, timeZone: .current)
            return expression.flatMap { compiler.compile($0) }
        }
        containsRegex = root?.containsRegex ?? false
    }

    public var matchesEverything: Bool { root == nil }

    public func matches(_ entry: LogEntry) -> Bool {
        guard let root else { return true }
        return root.evaluate(entry)
    }
}

/// NSRegularExpression is immutable after creation and safe to share.
private struct SharedRegex: @unchecked Sendable { let regex: NSRegularExpression }

private enum Comparison: Sendable {
    case equal, less, lessOrEqual, greater, greaterOrEqual

    init?(_ match: MatchKind) {
        switch match {
        case .is: self = .equal
        case .lessThan: self = .less
        case .lessOrEqual: self = .lessOrEqual
        case .greaterThan: self = .greater
        case .greaterOrEqual: self = .greaterOrEqual
        default: return nil
        }
    }

    func test<T: Comparable>(_ lhs: T?, _ rhs: T) -> Bool {
        guard let lhs else { return false }
        return switch self {
        case .equal: lhs == rhs
        case .less: lhs < rhs
        case .lessOrEqual: lhs <= rhs
        case .greater: lhs > rhs
        case .greaterOrEqual: lhs >= rhs
        }
    }
}

/// Compiles one tree, tracking the links being resolved so a loop is dropped.
private struct Compiler {
    let resolve: (UUID) -> FilterExpression?
    let timeZone: TimeZone
    var path: Set<UUID> = []

    mutating func compile(_ e: FilterExpression) -> Node? {
        switch e {
        case .condition(let c): return Node.compile(c, timeZone: timeZone)
        case .all(let xs): return group(xs).map(Node.all)
        case .any(let xs): return group(xs).map(Node.any)
        case .not(let x): return compile(x).map(Node.not)
        case .link(let id):
            guard !path.contains(id), let linked = resolve(id) else { return nil }
            path.insert(id)
            defer { path.remove(id) }
            return compile(linked)
        }
    }

    private mutating func group(_ xs: [FilterExpression]) -> [Node]? {
        // Cheapest first, so the short-circuit skips the expensive tests (a message search
        // is ~10x a process comparison). Evaluation is pure, so the result is unchanged.
        let nodes = xs.compactMap { compile($0) }.sorted { $0.cost < $1.cost }
        return nodes.isEmpty ? nil : nodes
    }
}

private indirect enum Node: Sendable {
    case text(TextSource, TextTest)
    case pid(Comparison, Int32)
    case thread(Comparison, UInt64)
    case activity(Comparison, UInt64)
    case level(Comparison, Int)
    /// Local wall-clock seconds since midnight in `[start, endStart + endLength)`. It wraps past
    /// midnight when start > endStart (decided on the end's start, so `22:00`–`21:59` wraps).
    case timeOfDay(start: Double, endStart: Double, endLength: Double, TimeZone)
    case all([Node])
    case any([Node])
    case not(Node)

    enum TextSource: Sendable {
        case field(FilterField)
        case extra(String)
    }

    enum TextTest: Sendable {
        case contains(String), equals(String), prefix(String), suffix(String), regex(SharedRegex)

        func test(_ s: String) -> Bool {
            switch self {
            case .contains(let n): n.isEmpty || s.range(of: n, options: .caseInsensitive) != nil
            case .equals(let n): s.compare(n, options: .caseInsensitive) == .orderedSame
            case .prefix(let n):
                n.isEmpty || s.range(of: n, options: [.caseInsensitive, .anchored]) != nil
            case .suffix(let n):
                n.isEmpty
                    || s.range(of: n, options: [.caseInsensitive, .anchored, .backwards]) != nil
            case .regex(let r): Self.matchesWhole(r.regex, s)
            }
        }

        /// The regex is wrapped in `\A(?:…)\z` (`FilterCondition.wholeValueRegex`), so any
        /// match covers the whole value, as MATCHES in `log` and NSPredicate.
        private static func matchesWhole(_ regex: NSRegularExpression, _ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
    }

    /// Rough relative cost of evaluating the node: numeric, level and time compares, then `is`,
    /// `starts with` and `ends with`, then `contains`, then regex; a test on the message costs
    /// far more than the same test on a short field. `sorted` is not stable, so equal costs
    /// may swap; harmless.
    var cost: Int {
        switch self {
        case .pid, .thread, .activity, .level, .timeOfDay: return 0
        case .text(let source, let test):
            let base = switch test {
            case .equals: 1
            case .prefix, .suffix: 2
            case .contains: 4
            case .regex: 40
            }
            let extra = switch source {
            case .field(.message): 20
            // A non-string Extra value is serialised on every evaluation.
            case .extra: 10
            case .field(.library): 1
            default: 0
            }
            return base + extra
        case .all(let xs), .any(let xs): return xs.reduce(0) { $0 + $1.cost }
        case .not(let x): return x.cost
        }
    }

    static func compile(_ c: FilterCondition, timeZone: TimeZone) -> Node? {
        guard c.isEnabled, c.valueProblem == nil, c.field.allowedMatches.contains(c.match) else {
            return nil
        }
        if c.match == .regex {
            guard let r = FilterCondition.wholeValueRegex(c.value) else { return nil }
            return .text(source(c), .regex(SharedRegex(regex: r)))
        }
        switch c.field {
        case .pid:
            guard let op = Comparison(c.match) else { return nil }
            return FilterCondition.parseInteger(c.value, as: Int32.self).map { .pid(op, $0) }
        case .activity:
            guard let op = Comparison(c.match) else { return nil }
            return FilterCondition.parseInteger(c.value, as: UInt64.self).map { .activity(op, $0) }
        case .thread:
            guard let op = Comparison(c.match) else { return nil }
            return FilterCondition.parseInteger(c.value, as: UInt64.self).map { .thread(op, $0) }
        case .type:
            guard let op = Comparison(c.match) else { return nil }
            return FilterCondition.parseLevel(c.value).map { .level(op, $0.logOrder) }
        case .timeOfDay:
            guard let start = FilterCondition.parseTime(c.value),
                  let end = c.upperValue.flatMap(FilterCondition.parseTime) else { return nil }
            return .timeOfDay(
                start: Double(start.start), endStart: Double(end.start),
                endLength: Double(end.length), timeZone)
        case .process, .library, .subsystem, .category, .message, .eventType, .processPath,
             .senderPath, .extra:
            let test: TextTest
            switch c.match {
            case .contains: test = .contains(c.value)
            case .is: test = .equals(c.value)
            case .startsWith: test = .prefix(c.value)
            case .endsWith: test = .suffix(c.value)
            default: return nil
            }
            return .text(source(c), test)
        }
    }

    private static func source(_ c: FilterCondition) -> TextSource {
        c.field == .extra ? .extra(c.key ?? "") : .field(c.field)
    }

    var containsRegex: Bool {
        switch self {
        case .text(_, .regex): true
        case .text, .pid, .thread, .activity, .level, .timeOfDay: false
        case .all(let xs), .any(let xs): xs.contains { $0.containsRegex }
        case .not(let x): x.containsRegex
        }
    }

    func evaluate(_ entry: LogEntry) -> Bool {
        switch self {
        case .text(let source, let test):
            guard let s = Node.value(of: source, in: entry) else { return false }
            return test.test(s)
        case .pid(let op, let v): return op.test(entry.pid, v)
        case .thread(let op, let v): return op.test(entry.threadID, v)
        case .activity(let op, let v): return op.test(entry.activityID, v)
        case .level(let op, let v): return op.test(entry.level.logOrder, v)
        case .timeOfDay(let start, let endStart, let endLength, let zone):
            let t = Node.secondsSinceLocalMidnight(entry.date, zone)
            let end = endStart + endLength
            return start > endStart ? (t >= start || t < end) : (t >= start && t < end)
        case .all(let xs): return xs.allSatisfy { $0.evaluate(entry) }
        case .any(let xs): return xs.contains { $0.evaluate(entry) }
        case .not(let x): return !x.evaluate(entry)
        }
    }

    /// Local wall-clock time of day, in seconds (fractions kept). Midnight UTC falls on whole
    /// days since the epoch, so shifting by the zone's offset at that instant gives local time.
    private static func secondsSinceLocalMidnight(_ date: Date, _ zone: TimeZone) -> Double {
        let local = date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))
        let t = local.truncatingRemainder(dividingBy: 86_400)
        return t < 0 ? t + 86_400 : t
    }

    /// The text a text or regex test reads; nil (never matches) when the entry has none.
    private static func value(of source: TextSource, in e: LogEntry) -> String? {
        switch source {
        case .extra(let key): return e.extra[key].map(ExtraValueText.text)
        case .field(let field):
            switch field {
            case .process: return e.process
            case .message: return e.message
            case .subsystem: return e.subsystem
            case .category: return e.category
            case .library: return e.libraryName
            case .eventType: return e.eventType
            case .processPath: return e.processImagePath
            case .senderPath: return e.senderImagePath
            // Regex on numbers matches the value as the list shows it (ES §5.2).
            case .pid: return e.pid.map { String($0) }
            case .activity: return e.activityID.map { String($0) }
            case .thread: return e.threadID.map { "0x" + String($0, radix: 16) }
            case .type: return e.level.rawValue.lowercased()
            case .timeOfDay, .extra: return nil
            }
        }
    }
}

/// An Extra data value as filter text: strings unquoted, anything else as compact JSON with
/// sorted keys.
enum ExtraValueText {
    static func text(_ value: JSONValue) -> String {
        if case .string(let s) = value { return s }
        let options: JSONSerialization.WritingOptions =
            [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: object(value), options: options)
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        case .array(let a): a.map(object)
        case .object(let o): o.mapValues(object)
        }
    }
}
