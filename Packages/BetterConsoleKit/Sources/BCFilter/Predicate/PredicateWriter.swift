import Foundation

/// Child indexes from the root of a `FilterExpression` (`.not` has one child, index 0).
public typealias NodePath = [Int]

/// A tree written as predicate text (ES §6.2), with the parts only BetterConsole understands
/// (ES §6.3) and the text of each tree node.
public struct PredicateText: Sendable {
    public var text: String
    /// App-only conditions and links, whole disabled `//` lines and nested `TRUEPREDICATE`s,
    /// in text order.
    public var appOnlyRanges: [Range<String.Index>]
    /// The text written for each node. A node written without text of its own (a group with
    /// one member, a group flattened into a same-operator parent, `NOT NOT x`) maps to the text
    /// of what it contains.
    public var nodeRanges: [NodePath: Range<String.Index>]

    public init(
        text: String, appOnlyRanges: [Range<String.Index>], nodeRanges: [NodePath: Range<String.Index>]
    ) {
        self.text = text
        self.appOnlyRanges = appOnlyRanges
        self.nodeRanges = nodeRanges
    }
}

/// Writes a filter tree in one fixed layout (ES §6.2, §13.1, §13.2):
///
/// - one member per line; each line after the first starts with its group's connector;
/// - parentheses only where the operator changes, members indented 5 spaces per level;
/// - a disabled member as `// [connector ]<member>` on its own line, so a group whose first
///   member is disabled leaves `(` alone on its line, and one whose last member is disabled
///   puts `)` on its own line;
/// - None of / Not all of as `NOT <member>` or `NOT (…)`; `NOT NOT x` as `x`, also with
///   one-member groups between the two NOTs;
/// - an empty tree, or a group or exclusion with nothing in it, as `TRUEPREDICATE` (app-only
///   when nested, as `log` would read it as matching everything).
public enum PredicateWriter {
    public static func write(
        _ e: FilterExpression?, nameForLink: (UUID) -> String?
    ) -> PredicateText {
        withoutActuallyEscaping(nameForLink) { nameForLink in
            var w = Writer(nameForLink: nameForLink)
            if let e {
                var first = true
                w.member(e, [], op: Writer.sequenceOperator(e) ?? .and, depth: 0, first: &first)
            } else {
                w.emit("TRUEPREDICATE")
            }
            return w.result()
        }
    }

    /// The text with the app-only parts left out (ES §6.5): app-only conditions, links and
    /// disabled conditions are removed, then groups and exclusions left empty. `removed`
    /// counts the conditions and links removed.
    public static func logPredicate(
        _ e: FilterExpression?, nameForLink: (UUID) -> String?
    ) -> (text: String, removed: Int) {
        var removed = 0
        let kept = e.flatMap { withoutAppOnly($0, removed: &removed) }
        return (write(kept, nameForLink: nameForLink).text, removed)
    }

    /// Parts `log` can't use (ES §6.3): disabled conditions, invalid ones (written as they
    /// are, for the user to fix), app-only fields, regex on number fields and Type, and any
    /// Event type match but `==` with one of `log`'s event type names (`log` reads eventType
    /// as a numeric enum).
    static func isAppOnly(_ c: FilterCondition) -> Bool {
        if !c.isEnabled || c.valueProblem != nil { return true }
        switch c.field {
        case .timeOfDay, .extra: return true
        case .pid, .thread, .activity, .type: return c.match == .regex
        case .eventType: return c.match != .is || !logEventTypes.contains(c.value)
        default: return false
        }
    }

    /// The eventType names `log` accepts, exactly as it spells them.
    static let logEventTypes: Set<String> = [
        "activityCreateEvent", "activityTransitionEvent", "logEvent", "signpostEvent",
        "stateEvent", "timesyncEvent", "traceEvent", "userActionEvent",
    ]

    private static func withoutAppOnly(_ e: FilterExpression, removed: inout Int) -> FilterExpression? {
        switch e {
        case .condition(let c):
            if isAppOnly(c) { removed += 1; return nil }
            return e
        case .link:
            removed += 1
            return nil
        case .all(let xs):
            let kept = xs.compactMap { withoutAppOnly($0, removed: &removed) }
            return kept.isEmpty ? nil : .all(kept)
        case .any(let xs):
            let kept = xs.compactMap { withoutAppOnly($0, removed: &removed) }
            return kept.isEmpty ? nil : .any(kept)
        case .not(let x):
            return withoutAppOnly(x, removed: &removed).map(FilterExpression.not)
        }
    }
}

private struct Writer {
    enum Operator {
        case and, or
        var connector: String { self == .and ? "AND" : "OR" }
    }

    let nameForLink: (UUID) -> String?
    private var out = ""
    /// Ranges as UTF-8 offsets into `out`, turned into indexes once the text is complete.
    private var appOnly: [Range<Int>] = []
    private var nodes: [NodePath: Range<Int>] = [:]

    init(nameForLink: @escaping (UUID) -> String?) {
        self.nameForLink = nameForLink
    }

    static func operatorOf(_ e: FilterExpression) -> Operator? {
        switch e {
        case .all: .and
        case .any: .or
        default: nil
        }
    }

    /// The operator `e` is written with when it is not parenthesised: a group with one member
    /// and `NOT NOT x` take it from what they contain.
    static func sequenceOperator(_ e: FilterExpression) -> Operator? {
        switch e {
        case .all(let xs): xs.count == 1 ? sequenceOperator(xs[0]) ?? .and : .and
        case .any(let xs): xs.count == 1 ? sequenceOperator(xs[0]) ?? .or : .or
        case .not: doubleNegation(e, []).flatMap { sequenceOperator($0.inner) }
        default: nil
        }
    }

    /// `e` with one-member groups looked through: the node reached, its path, and the paths of
    /// the groups passed on the way.
    static func unwrapSingle(
        _ e: FilterExpression, _ path: NodePath
    ) -> (node: FilterExpression, path: NodePath, skipped: [NodePath]) {
        var e = e, path = path, skipped: [NodePath] = []
        while true {
            switch e {
            case .all(let xs) where xs.count == 1, .any(let xs) where xs.count == 1:
                skipped.append(path)
                e = xs[0]
                path += [0]
            default:
                return (e, path, skipped)
            }
        }
    }

    /// For `NOT NOT x`, also through one-member groups between the two NOTs (the parser reads
    /// `NOT NOT x` as `x`): `x`, its path, and the paths of the nodes between `e` and `x`.
    static func doubleNegation(
        _ e: FilterExpression, _ path: NodePath
    ) -> (inner: FilterExpression, path: NodePath, wrappers: [NodePath])? {
        guard case .not(let x) = e else { return nil }
        let u = unwrapSingle(x, path + [0])
        guard case .not(let y) = u.node else { return nil }
        return (y, u.path + [0], u.skipped + [u.path])
    }

    func result() -> PredicateText {
        let text = out
        func range(_ r: Range<Int>) -> Range<String.Index> {
            let utf8 = text.utf8
            return utf8.index(utf8.startIndex, offsetBy: r.lowerBound)
                ..< utf8.index(utf8.startIndex, offsetBy: r.upperBound)
        }
        // A whole text of TRUEPREDICATE means the same in `log`; only a nested one is app-only.
        let appOnly = text == "TRUEPREDICATE" ? [] : self.appOnly
        return PredicateText(
            text: text, appOnlyRanges: appOnly.map(range),
            nodeRanges: nodes.mapValues(range))
    }

    // MARK: Output

    private var offset: Int { out.utf8.count }

    mutating func emit(_ s: String) { out += s }

    private mutating func newline(depth: Int) {
        out += "\n" + String(repeating: " ", count: depth * 5)
    }

    /// The text after the last line break.
    private var currentLine: Substring {
        out.lastIndex(of: "\n").map { out[out.index(after: $0)...] } ?? out[...]
    }

    // MARK: Layout

    /// Writes `e` as a member of a sequence joined by `op`, its lines indented `depth` levels.
    /// A group whose members can join that sequence without parentheses (same operator, or a
    /// single member) is written member by member in it.
    @discardableResult
    mutating func member(
        _ e: FilterExpression, _ path: NodePath, op: Operator, depth: Int, first: inout Bool
    ) -> Range<Int> {
        if let n = Self.doubleNegation(e, path) {
            let range = member(n.inner, n.path, op: op, depth: depth, first: &first)
            for w in n.wrappers + [path] { nodes[w] = range }
            return range
        }
        let range: Range<Int>
        switch e {
        // A group with nothing in it is one TRUEPREDICATE (via `term`), not one per member.
        case .all(let xs) where !Self.isEmpty(e) && (op == .and || xs.count == 1),
             .any(let xs) where !Self.isEmpty(e) && (op == .or || xs.count == 1):
            var r: Range<Int>?
            for (i, x) in xs.enumerated() {
                let m = member(x, path + [i], op: op, depth: depth, first: &first)
                r = r.map { $0.lowerBound ..< m.upperBound } ?? m
            }
            range = r!
        case .condition(let c) where !c.isEnabled:
            if !first || !currentLine.allSatisfy(\.isWhitespace) { newline(depth: depth) }
            let start = offset
            emit("// " + (first ? "" : op.connector + " ") + comparison(c))
            range = start ..< offset
            appOnly.append(range)
            first = false
        default:
            if !first { newline(depth: depth); emit(op.connector + " ") }
            first = false
            range = term(e, path, depth: depth)
        }
        nodes[path] = range
        return range
    }

    /// Writes `e` as one operand: a comparison, a link, `NOT …`, or a parenthesised group whose
    /// members are indented one level deeper than `depth`.
    @discardableResult
    private mutating func term(_ e: FilterExpression, _ path: NodePath, depth: Int) -> Range<Int> {
        if let n = Self.doubleNegation(e, path) {
            let range = term(n.inner, n.path, depth: depth)
            for w in n.wrappers + [path] { nodes[w] = range }
            return range
        }
        let start = offset
        switch e {
        case .condition(let c) where c.isEnabled:
            emit(comparison(c))
            if PredicateWriter.isAppOnly(c) { appOnly.append(start ..< offset) }
        case .link(let id):
            emit("filter == " + quoted(nameForLink(id) ?? "<missing:\(id.uuidString)>"))
            appOnly.append(start ..< offset)
        case .all(let xs) where xs.count == 1, .any(let xs) where xs.count == 1:
            term(xs[0], path + [0], depth: depth)
        case _ where Self.isEmpty(e):
            // In `log` it matches everything; the app drops an empty group.
            emit("TRUEPREDICATE")
            appOnly.append(start ..< offset)
        case .not(let x):
            emit("NOT ")
            term(x, path + [0], depth: depth)
        default:
            // A group of two or more members, or a disabled condition under NOT (no NOT on a
            // disabled line): parenthesised.
            emit("(")
            var first = true
            let inner = member(e, path, op: Self.operatorOf(e) ?? .and, depth: depth + 1, first: &first)
            if currentLine.drop(while: \.isWhitespace).hasPrefix("//") { newline(depth: depth) }
            emit(")")
            // The disabled condition itself maps to its `//` line, not the parentheses.
            if case .condition = e { return inner }
        }
        let range = start ..< offset
        nodes[path] = range
        return range
    }

    /// No condition or link anywhere below: imposes no constraint, even under NOT.
    private static func isEmpty(_ e: FilterExpression) -> Bool {
        switch e {
        case .condition, .link: false
        case .all(let xs), .any(let xs): xs.allSatisfy(isEmpty)
        case .not(let x): isEmpty(x)
        }
    }

    // MARK: Comparisons

    private func comparison(_ c: FilterCondition) -> String {
        let key = c.field == .extra ? "extra[\(quoted(c.key ?? ""))]" : c.field.predicateKey
        switch c.match {
        case .contains: return "\(key) CONTAINS[c] \(quoted(c.value))"
        case .startsWith: return "\(key) BEGINSWITH[c] \(quoted(c.value))"
        case .endsWith: return "\(key) ENDSWITH[c] \(quoted(c.value))"
        case .regex: return "\(key) MATCHES[c] \(quoted(c.value))"
        case .between:
            return "\(key) BETWEEN {\(quoted(c.value)), \(quoted(c.upperValue ?? ""))}"
        case .is, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual:
            let op = switch c.match {
            case .lessThan: "<"
            case .lessOrEqual: "<="
            case .greaterThan: ">"
            case .greaterOrEqual: ">="
            default: "=="
            }
            switch c.field {
            case .pid, .thread, .activity, .type:
                return "\(key) \(op) \(literal(c) ?? quoted(c.value))"
            default:
                return "\(key) \(op)\(c.match == .is ? "[c]" : "") \(quoted(c.value))"
            }
        }
    }

    /// The bare value of a numeric or Type comparison; nil for text fields and for a value the
    /// field can't use (written as a string instead).
    private func literal(_ c: FilterCondition) -> String? {
        switch c.field {
        case .pid, .activity, .thread, .type: FilterNormaliser.literal(c)
        default: nil
        }
    }

    /// `"…"` with `\` and `"` escaped, and line breaks and tabs as `\n`, `\r`, `\t` so a value
    /// can't end a `//` line or break the layout.
    private func quoted(_ s: String) -> String {
        var r = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": r += "\\\\"
            case "\"": r += "\\\""
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default: r.unicodeScalars.append(ch)
            }
        }
        return r + "\""
    }
}
