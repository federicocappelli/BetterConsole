import BCModel
import Foundation

/// A filter expression compiled once for fast per-entry evaluation. Disabled and invalid
/// conditions are dropped as if absent; groups left empty impose no constraint.
public struct CompiledFilter: Sendable {
    private let root: Node?
    /// Whether any kept condition is a regex. Regex evaluation can take very long per entry
    /// (catastrophic backtracking), so long-running callers check for cancellation per entry.
    public let containsRegex: Bool

    public init(_ expression: FilterExpression?) {
        root = expression.flatMap(Node.compile)
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

private indirect enum Node: Sendable {
    case text(FilterField, TextTest)
    case pid(Int32)
    case thread(UInt64)
    case activity(UInt64)
    case level(LogLevel)
    case all([Node])
    case any([Node])
    case not(Node)

    enum TextTest: Sendable {
        case contains(String), equals(String), prefix(String), regex(SharedRegex)

        func test(_ s: String) -> Bool {
            switch self {
            case .contains(let n): n.isEmpty || s.range(of: n, options: .caseInsensitive) != nil
            case .equals(let n): s.compare(n, options: .caseInsensitive) == .orderedSame
            case .prefix(let n):
                n.isEmpty || s.range(of: n, options: [.caseInsensitive, .anchored]) != nil
            case .regex(let r):
                r.regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            }
        }
    }

    static func compile(_ e: FilterExpression) -> Node? {
        switch e {
        case .condition(let c): compile(c)
        case .all(let xs): group(xs).map(Node.all)
        case .any(let xs): group(xs).map(Node.any)
        case .not(let x): compile(x).map(Node.not)
        }
    }

    private static func group(_ xs: [FilterExpression]) -> [Node]? {
        // Cheapest first, so the short-circuit skips the expensive tests (a message search
        // is ~10x a process comparison). Evaluation is pure, so the result is unchanged.
        let nodes = xs.compactMap(compile).sorted { $0.cost < $1.cost }
        return nodes.isEmpty ? nil : nodes
    }

    /// Rough relative cost of evaluating the node: numeric and level compares, then `is` and
    /// `starts with`, then `contains`, then regex; a test on the message costs far more than the
    /// same test on a short field. `sorted` is not stable, so equal costs may swap; harmless.
    var cost: Int {
        switch self {
        case .pid, .thread, .activity, .level: return 0
        case .text(let field, let test):
            let base = switch test {
            case .equals: 1
            case .prefix: 2
            case .contains: 4
            case .regex: 40
            }
            return base + (field == .message ? 20 : field == .library ? 1 : 0)
        case .all(let xs), .any(let xs): return xs.reduce(0) { $0 + $1.cost }
        case .not(let x): return x.cost
        }
    }

    private static func compile(_ c: FilterCondition) -> Node? {
        guard c.isEnabled, c.valueProblem == nil, c.field.allowedMatches.contains(c.match) else {
            return nil
        }
        switch c.field {
        case .pid: return FilterCondition.parseDecimal(c.value, as: Int32.self).map(Node.pid)
        case .activity: return FilterCondition.parseDecimal(c.value, as: UInt64.self).map(Node.activity)
        case .thread: return FilterCondition.parseThread(c.value).map(Node.thread)
        case .type: return FilterCondition.parseLevel(c.value).map(Node.level)
        case .process, .library, .subsystem, .category, .message:
            let test: TextTest
            switch c.match {
            case .contains: test = .contains(c.value)
            case .is: test = .equals(c.value)
            case .startsWith: test = .prefix(c.value)
            case .regex:
                guard let r = try? NSRegularExpression(pattern: c.value, options: .caseInsensitive)
                else { return nil }
                test = .regex(SharedRegex(regex: r))
            }
            return .text(c.field, test)
        }
    }

    var containsRegex: Bool {
        switch self {
        case .text(_, .regex): true
        case .text, .pid, .thread, .activity, .level: false
        case .all(let xs), .any(let xs): xs.contains { $0.containsRegex }
        case .not(let x): x.containsRegex
        }
    }

    func evaluate(_ entry: LogEntry) -> Bool {
        switch self {
        case .text(let field, let test):
            guard let s = Node.value(of: field, in: entry) else { return false }
            return test.test(s)
        case .pid(let v): return entry.pid == v
        case .thread(let v): return entry.threadID == v
        case .activity(let v): return entry.activityID == v
        case .level(let v): return entry.level == v
        case .all(let xs): return xs.allSatisfy { $0.evaluate(entry) }
        case .any(let xs): return xs.contains { $0.evaluate(entry) }
        case .not(let x): return !x.evaluate(entry)
        }
    }

    private static func value(of field: FilterField, in e: LogEntry) -> String? {
        switch field {
        case .process: return e.process
        case .message: return e.message
        case .subsystem: return e.subsystem
        case .category: return e.category
        case .library: return e.libraryName
        default: return nil
        }
    }
}
