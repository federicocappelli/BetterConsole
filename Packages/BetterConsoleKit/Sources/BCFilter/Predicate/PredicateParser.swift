import Foundation

/// A problem in predicate text: where it is and a plain sentence about it (ES §6.1).
public struct PredicateParseError: Error, Equatable, Sendable {
    public var range: Range<String.Index>
    public var message: String

    public init(range: Range<String.Index>, message: String) {
        self.range = range
        self.message = message
    }
}

/// What a saved filter's name refers to (ES §6.6).
public enum LinkLookup: Equatable, Sendable {
    case found(UUID)
    case notFound
    /// Linking it from the filter being edited would make a loop.
    case wouldLoop
}

/// A tree read from text, with where each of its nodes is in that text.
public struct ParsedPredicate: Sendable {
    public var expression: FilterExpression?
    public var text: PredicateText
}

/// Reads predicate text into a filter tree (ES §6.1 with the §13 overrides). Reading what
/// `PredicateWriter` wrote gives `FilterNormaliser.normalised` of the tree written, and
/// writing that gives the same text back.
///
/// - `AND` binds tighter than `OR`; parentheses make a group only where the operator changes
///   (`(a AND b) AND c` is one All of group).
/// - `a != b` and `a <> b` read as `NOT a == b`; `NOT NOT x` as `x`.
/// - `TRUEPREDICATE` is nil as the whole text and `.all([])` as an operand.
/// - `// [AND|OR] <comparison>` on its own line is a disabled condition of the group around it
///   (ES §13.2).
/// - A link written to a filter that no longer exists, `filter == "<missing:UUID>"`, reads
///   back as a link to that id without asking `linkForName`.
public enum PredicateParser {
    public static func parse(
        _ text: String, linkForName: (String) -> LinkLookup
    ) -> Result<FilterExpression?, PredicateParseError> {
        parse(text, linkForName: linkForName, conditionProblem: { _ in nil })
    }

    /// As above, and a condition `conditionProblem` objects to is an error at its value (file
    /// import rejects what the editor shows as a value problem, ES §7.2).
    static func parse(
        _ text: String, linkForName: (String) -> LinkLookup,
        conditionProblem: (FilterCondition) -> String?
    ) -> Result<FilterExpression?, PredicateParseError> {
        parseWithLeaves(text, linkForName: linkForName, conditionProblem: conditionProblem)
            .map(\.expression)
    }

    /// As `parse`, with where each node of the tree read is in `text`, keyed as
    /// `PredicateText.nodeRanges` is, so text the user is typing (not the writer's layout) can
    /// still be mapped to builder rows (R13). A condition or link covers its comparison; a
    /// group or exclusion spans its first to its last condition or link (parentheses and
    /// `NOT` are not included). App-only conditions and links are in `appOnlyRanges`.
    public static func parseWithRanges(
        _ text: String, linkForName: (String) -> LinkLookup
    ) -> Result<ParsedPredicate, PredicateParseError> {
        parseWithLeaves(text, linkForName: linkForName, conditionProblem: { _ in nil }).map { parsed in
            var ranges = Ranges(leaves: parsed.leaves)
            if let e = parsed.expression { _ = ranges.assign(e, at: []) }
            // Conditions and links are read in text order and the tree keeps that order, so
            // the leaves pair up one to one; anything else is a bug, and no ranges are better
            // than wrong ones.
            guard ranges.next == parsed.leaves.count else {
                return ParsedPredicate(
                    expression: parsed.expression,
                    text: PredicateText(text: text, appOnlyRanges: [], nodeRanges: [:]))
            }
            return ParsedPredicate(
                expression: parsed.expression,
                text: PredicateText(text: text, appOnlyRanges: ranges.appOnly, nodeRanges: ranges.nodes))
        }
    }

    /// Hands out the comparisons' ranges to the tree's conditions and links in order.
    private struct Ranges {
        let leaves: [Range<String.Index>]
        var next = 0
        var nodes: [NodePath: Range<String.Index>] = [:]
        var appOnly: [Range<String.Index>] = []

        mutating func assign(_ e: FilterExpression, at path: NodePath) -> Range<String.Index>? {
            let range: Range<String.Index>?
            switch e {
            case .condition, .link:
                guard next < leaves.count else { return nil }
                range = leaves[next]
                next += 1
                let isAppOnly = if case .condition(let c) = e { PredicateWriter.isAppOnly(c) } else { true }
                if isAppOnly { appOnly.append(leaves[next - 1]) }
            case .all(let xs), .any(let xs):
                let inner = xs.enumerated().compactMap { i, x in assign(x, at: path + [i]) }
                range = inner.first.map { $0.lowerBound..<inner.last!.upperBound }
            case .not(let x):
                range = assign(x, at: path + [0])
            }
            if let range { nodes[path] = range }
            return range
        }
    }

    private static func parseWithLeaves(
        _ text: String, linkForName: (String) -> LinkLookup,
        conditionProblem: (FilterCondition) -> String?
    ) -> Result<(expression: FilterExpression?, leaves: [Range<String.Index>]), PredicateParseError> {
        withoutActuallyEscaping(linkForName) { linkForName in
            withoutActuallyEscaping(conditionProblem) { conditionProblem in
                var p = Parser(text: text, tokens: PredicateLexer.tokens(text), linkForName: linkForName)
                p.conditionProblem = conditionProblem
                do throws(PredicateParseError) {
                    let e = try p.parseFilter()
                    return .success((e, p.leafRanges))
                } catch {
                    return .failure(error)
                }
            }
        }
    }
}

private struct Parser {
    enum Operator: Equatable {
        case and, or
        var word: String { self == .and ? "AND" : "OR" }
    }

    /// An operand of a sequence, with the connector written before it.
    struct Item {
        var expr: FilterExpression
        var connector: (op: Operator, range: Range<String.Index>)?
        var isDisabled = false
        /// Set for a parenthesised group, so a group with the same operator as the sequence
        /// around it is flattened into it.
        var groupOperator: Operator?
    }

    let text: String
    let tokens: [PredicateToken]
    let linkForName: (String) -> LinkLookup
    var conditionProblem: (FilterCondition) -> String? = { _ in nil }
    var pos = 0
    /// Each comparison read (condition or link), in text order.
    var leafRanges: [Range<String.Index>] = []
    /// Levels of parentheses allowed; deeper is "Too deeply nested". This only keeps the
    /// parse itself bounded: the tree read must also be within `FilterFile.maxDepth`.
    static let maxDepth = 200

    init(text: String, tokens: [PredicateToken], linkForName: @escaping (String) -> LinkLookup) {
        self.text = text
        self.tokens = tokens
        self.linkForName = linkForName
    }

    // MARK: Tokens

    static let reserved: Set<String> = ["WHEN", "THEN", "IF", "ELSE"]
    static let keywords: Set<String> = [
        "AND", "OR", "NOT", "TRUEPREDICATE", "CONTAINS", "BEGINSWITH", "ENDSWITH", "MATCHES",
        "LIKE", "BETWEEN",
    ]

    /// The current token; an error when it is invalid text or a reserved word.
    func current() throws(PredicateParseError) -> PredicateToken {
        let t = tokens[pos]
        switch t.kind {
        case .invalid(let message):
            throw PredicateParseError(range: t.range, message: message)
        case .word(let w) where Self.reserved.contains(w.uppercased()):
            throw PredicateParseError(range: t.range, message: "Reserved for a future version")
        default:
            return t
        }
    }

    mutating func advance() { if pos < tokens.count - 1 { pos += 1 } }

    static func keyword(_ t: PredicateToken) -> String? {
        if case .word(let w) = t.kind {
            let u = w.uppercased()
            return keywords.contains(u) ? u : nil
        }
        return nil
    }

    static func connector(_ t: PredicateToken) -> Operator? {
        switch t.kind {
        case .symbol("&&"): .and
        case .symbol("||"): .or
        default:
            switch keyword(t) {
            case "AND": .and
            case "OR": .or
            default: nil
            }
        }
    }

    static func isNot(_ t: PredicateToken) -> Bool {
        t.kind == .symbol("!") || keyword(t) == "NOT"
    }

    func source(_ t: PredicateToken) -> String { String(text[t.range]) }

    func error(_ message: String, at t: PredicateToken) -> PredicateParseError {
        PredicateParseError(range: t.range, message: message)
    }

    // MARK: Structure

    mutating func parseFilter() throws(PredicateParseError) -> FilterExpression? {
        guard let e = try parseText(), e != .all([]) else { return nil }
        try checkDepth(e)
        return e
    }

    /// Every tree the app keeps is within `FilterFile.maxDepth`, counted as files count it.
    /// Past it, "Too deeply nested" is reported at the first condition or link (in text order)
    /// at or below the first node past the cap.
    func checkDepth(_ e: FilterExpression) throws(PredicateParseError) {
        guard FilterFile.depth(e) > FilterFile.maxDepth else { return }
        /// Pre-order: the number of leaves before the first node past the cap.
        func leavesBefore(_ e: FilterExpression, level: Int, count: inout Int) -> Bool {
            if level > FilterFile.maxDepth { return true }
            switch e {
            case .condition, .link:
                count += 1
                return false
            case .all(let xs), .any(let xs):
                return xs.contains { leavesBefore($0, level: level + 1, count: &count) }
            case .not(let x):
                return leavesBefore(x, level: level + 1, count: &count)
            }
        }
        var count = 0
        _ = leavesBefore(e, level: 1, count: &count)
        // An empty group past the cap has no leaf of its own: the one before it stands in.
        let range = leafRanges.isEmpty
            ? text.startIndex..<text.endIndex
            : leafRanges[min(count, leafRanges.count - 1)]
        throw PredicateParseError(range: range, message: "Too deeply nested")
    }

    /// A sequence being read: the whole text, or the inside of a `(`.
    struct Frame {
        /// The `(`, nil for the whole text.
        var open: PredicateToken?
        var items: [Item] = []
        /// A connector read, waiting for its operand.
        var pending: PredicateToken?
        /// For a `(`: the connector before it, and whether an odd run of NOTs precedes it.
        var connector: PredicateToken?
        var negated = false
    }

    /// The whole text as one group, nil when it has no operands. Parentheses are kept on an
    /// explicit stack rather than by recursion, so deep nesting can't exhaust the call stack;
    /// more than `maxDepth` levels is an error.
    mutating func parseText() throws(PredicateParseError) -> FilterExpression? {
        var stack = [Frame()]
        while true {
            let t = try current()
            if t.kind == .disabledStart {
                if let pending = stack[stack.count - 1].pending {
                    throw error("Expected a condition after \(source(pending))", at: pending)
                }
                let item = try parseDisabledLine()
                stack[stack.count - 1].items.append(item)
                continue
            }
            if Self.connector(t) != nil {
                if let pending = stack[stack.count - 1].pending {
                    throw error("Expected a condition after \(source(pending))", at: pending)
                }
                if stack[stack.count - 1].items.isEmpty { throw error("Expected a condition", at: t) }
                stack[stack.count - 1].pending = t
                advance()
                continue
            }
            if t.kind == .end || t.kind == .symbol(")") {
                let frame = stack.removeLast()
                if let pending = frame.pending {
                    throw error("Expected a condition after \(source(pending))", at: pending)
                }
                if t.kind == .symbol(")"), frame.open == nil { throw error("This ) has no matching (", at: t) }
                if t.kind == .end, let open = frame.open { throw error("Unclosed parenthesis", at: open) }
                if frame.items.isEmpty {
                    if let open = frame.open { throw error("Expected a condition after (", at: open) }
                    return nil
                }
                let inner = try join(frame.items)
                guard !stack.isEmpty else { return inner }
                advance() // `)`
                var item = Self.negated(
                    Item(expr: inner, groupOperator: Self.groupOperator(inner)), frame.negated)
                item.connector = frame.connector.map { (Self.connector($0)!, $0.range) }
                stack[stack.count - 1].items.append(item)
                continue
            }
            if !stack[stack.count - 1].items.isEmpty, stack[stack.count - 1].pending == nil {
                throw error("Expected AND or OR", at: t)
            }
            // An operand: a run of NOTs (only its parity matters), then `(` or a primary.
            var negated = false
            var lastNot: PredicateToken?
            while Self.isNot(try current()) {
                negated.toggle()
                lastNot = tokens[pos]
                advance()
            }
            let pending = stack[stack.count - 1].pending
            stack[stack.count - 1].pending = nil
            let u = try current()
            if u.kind == .symbol("(") {
                if stack.count > Self.maxDepth { throw error("Too deeply nested", at: u) }
                advance()
                stack.append(Frame(open: u, connector: pending, negated: negated))
                continue
            }
            var item = Self.negated(try parsePrimary(after: lastNot), negated)
            item.connector = pending.map { (Self.connector($0)!, $0.range) }
            stack[stack.count - 1].items.append(item)
        }
    }

    /// `item` under NOT when `negated`: NOT NOT x is x, NOT TRUEPREDICATE is TRUEPREDICATE.
    static func negated(_ item: Item, _ negated: Bool) -> Item {
        guard negated else { return item }
        switch item.expr {
        case .all([]): return Item(expr: .all([]))
        case .not(let x): return Item(expr: x, groupOperator: groupOperator(x))
        default: return Item(expr: .not(item.expr))
        }
    }

    /// A group of nothing but TRUEPREDICATEs is TRUEPREDICATE, as the writer has it.
    static func collapsed(_ e: FilterExpression) -> FilterExpression {
        switch e {
        case .all(let xs), .any(let xs):
            xs.allSatisfy({ $0 == .all([]) }) ? .all([]) : e
        default:
            e
        }
    }

    /// The items as one group (ES §13.2): its operator comes from the connectors of the
    /// enabled operands, else from the disabled lines', else AND. A disabled line whose
    /// connector differs is an error. With both operators and no parentheses, see `mixed`.
    func join(_ items: [Item]) throws(PredicateParseError) -> FilterExpression {
        if items.count == 1 { return items[0].expr }
        let enabledOps = Set(items.filter { !$0.isDisabled }.compactMap { $0.connector?.op })
        if enabledOps.count == 2 { return try mixed(items) }
        let op = enabledOps.first
            ?? items.first(where: { $0.connector != nil })?.connector?.op
            ?? .and
        for item in items where item.isDisabled {
            try Self.check(item, in: op)
        }
        let members = Self.flattened(items, into: op)
        return Self.collapsed(op == .and ? .all(members) : .any(members))
    }

    /// AND and OR without parentheses: AND binds tighter, so the enabled operands form AND
    /// chains joined by OR. A disabled line belongs to the group whose lines surround it: the
    /// chain when the next enabled operand continues it (or, after the last operand, when the
    /// line says AND), else the OR group. Either way its connector must be that group's.
    func mixed(_ items: [Item]) throws(PredicateParseError) -> FilterExpression {
        /// The OR group's members in order: AND chains, and disabled lines between chains.
        var top: [[Item]] = []
        /// The chain enabled operands joined by AND go on.
        var chain: Int?
        for (i, item) in items.enumerated() {
            if !item.isDisabled {
                if let c = chain, item.connector?.op == .and {
                    top[c].append(item)
                } else {
                    top.append([item])
                    chain = top.count - 1
                }
                continue
            }
            let next = items[(i + 1)...].first { !$0.isDisabled }
            let inChain = chain != nil
                && (next.map { $0.connector?.op == .and } ?? (item.connector?.op == .and))
            if let c = chain, inChain {
                try Self.check(item, in: .and)
                top[c].append(item)
            } else {
                try Self.check(item, in: .or)
                top.append([item])
            }
        }
        let members = top.map { chain in
            chain.count == 1 ? chain[0]
                : Item(expr: Self.collapsed(.all(Self.flattened(chain, into: .and))), groupOperator: .and)
        }
        return Self.collapsed(.any(Self.flattened(members, into: .or)))
    }

    /// A disabled line's connector, if written, must be its group's operator.
    static func check(_ item: Item, in op: Operator) throws(PredicateParseError) {
        if let c = item.connector, c.op != op {
            throw PredicateParseError(
                range: c.range, message: "This line says \(c.op.word) but its group uses \(op.word)")
        }
    }

    /// The items' trees, with parenthesised groups of operator `op` spliced in.
    static func flattened(_ items: [Item], into op: Operator) -> [FilterExpression] {
        var out: [FilterExpression] = []
        for item in items {
            switch item.expr {
            case .all(let xs) where item.groupOperator == .and && op == .and: out += xs
            case .any(let xs) where item.groupOperator == .or && op == .or: out += xs
            default: out.append(item.expr)
            }
        }
        return out
    }

    /// The operator of a group read as one operand. Such a group only comes from parentheses
    /// (possibly under `NOT NOT`), so it flattens into a sequence with the same operator.
    static func groupOperator(_ e: FilterExpression) -> Operator? {
        switch e {
        case .all(let xs) where !xs.isEmpty: .and
        case .any(let xs) where !xs.isEmpty: .or
        default: nil
        }
    }

    mutating func parsePrimary(after: PredicateToken?) throws(PredicateParseError) -> Item {
        let t = try current()
        if Self.keyword(t) == "TRUEPREDICATE" {
            advance()
            return Item(expr: .all([]))
        }
        if case .word = t.kind, Self.keyword(t) == nil {
            return Item(expr: try parseComparison(disabled: false))
        }
        if t.kind == .end || t.kind == .symbol(")") || t.kind == .disabledStart
            || Self.connector(t) != nil, let after {
            throw error("Expected a condition after \(source(after))", at: after)
        }
        throw error("Expected a condition", at: t)
    }

    /// `// [AND|OR] <comparison>` up to the end of its line.
    mutating func parseDisabledLine() throws(PredicateParseError) -> Item {
        let start = tokens[pos]
        advance()
        var endIndex = pos
        while tokens[endIndex].kind != .disabledEnd { endIndex += 1 }
        let line = PredicateParseError(
            range: start.range.lowerBound..<Self.trimmedEnd(text, tokens[endIndex].range.lowerBound),
            message: PredicateLexer.onlyDisabledCondition)

        var connector: (op: Operator, range: Range<String.Index>)?
        if let op = Self.connector(tokens[pos]) {
            connector = (op, tokens[pos].range)
            advance()
        }
        let t = try current()
        guard case .word(let w) = t.kind, Self.keyword(t) == nil, w.lowercased() != "filter" else {
            throw line
        }
        // Free text after `//` is not a condition; a near miss of a key still gets a suggestion.
        if Self.field(named: w) == nil, w.lowercased() != "extra", Self.suggestion(for: w) == nil {
            throw line
        }
        let e = try parseComparison(disabled: true)
        guard case .condition = e, tokens[pos].kind == .disabledEnd else { throw line }
        advance()
        return Item(expr: e, connector: connector, isDisabled: true)
    }

    static func trimmedEnd(_ text: String, _ end: String.Index) -> String.Index {
        var e = end
        while e > text.startIndex {
            let p = text.unicodeScalars.index(before: e)
            guard text.unicodeScalars[p].properties.isWhitespace else { break }
            e = p
        }
        return e
    }

    // MARK: Comparisons

    static let fieldsByKey: [String: FilterField] = {
        var map: [String: FilterField] = [:]
        for f in FilterField.allCases where f != .extra { map[f.predicateKey.lowercased()] = f }
        map["composedmessage"] = .message
        return map
    }()

    static let keyNames: [String] =
        FilterField.allCases.map(\.predicateKey) + ["composedMessage", "filter"]

    static func field(named w: String) -> FilterField? { fieldsByKey[w.lowercased()] }

    /// The key within an edit distance of 2 of `w`, the closest first.
    static func suggestion(for w: String) -> String? {
        let lw = Array(w.lowercased())
        var best: (name: String, distance: Int)?
        for name in keyNames {
            let d = editDistance(lw, Array(name.lowercased()))
            if d <= 2, d < (best?.distance ?? .max) { best = (name, d) }
        }
        return best?.name
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, cb) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = ca == cb ? diagonal : 1 + min(diagonal, above, row[j])
                diagonal = above
            }
        }
        return row[b.count]
    }

    enum Op {
        case match(MatchKind)
        case notEqual
    }

    /// `key op value`, `key BETWEEN {a, b}` or `filter == "name"`.
    mutating func parseComparison(disabled: Bool) throws(PredicateParseError) -> FilterExpression {
        let start = tokens[pos].range.lowerBound
        let e = try parseComparisonBody(disabled: disabled)
        leafRanges.append(start..<tokens[pos - 1].range.upperBound)
        return e
    }

    private mutating func parseComparisonBody(disabled: Bool) throws(PredicateParseError) -> FilterExpression {
        let keyToken = try current()
        guard case .word(let word) = keyToken.kind else { throw error("Expected a condition", at: keyToken) }
        let lower = word.lowercased()
        advance()

        let field: FilterField?
        var key: String?
        switch lower {
        case "filter":
            field = nil
        case "extra":
            field = .extra
            guard try current().kind == .symbol("[") else {
                throw error(#"Expected extra["key"]"#, at: keyToken)
            }
            advance()
            guard case .string(let k) = try current().kind else {
                throw error(#"Expected extra["key"]"#, at: keyToken)
            }
            key = k
            advance()
            guard try current().kind == .symbol("]") else {
                throw error(#"Expected extra["key"]"#, at: keyToken)
            }
            advance()
        default:
            guard let f = Self.field(named: word) else {
                let message = Self.suggestion(for: word).map { "Unknown key ‘\(word)’. Did you mean ‘\($0)’?" }
                    ?? "Unknown key ‘\(word)’"
                throw error(message, at: keyToken)
            }
            field = f
        }
        let keyName = field?.predicateKey ?? "filter"

        // Operator.
        let opToken = try current()
        let op: Op
        switch opToken.kind {
        case .symbol("=="), .symbol("="): op = .match(.is)
        case .symbol("!="), .symbol("<>"): op = .notEqual
        case .symbol("<"): op = .match(.lessThan)
        case .symbol("<="), .symbol("=<"): op = .match(.lessOrEqual)
        case .symbol(">"): op = .match(.greaterThan)
        case .symbol(">="), .symbol("=>"): op = .match(.greaterOrEqual)
        default:
            switch Self.keyword(opToken) {
            case "CONTAINS": op = .match(.contains)
            case "BEGINSWITH": op = .match(.startsWith)
            case "ENDSWITH": op = .match(.endsWith)
            case "MATCHES": op = .match(.regex)
            case "BETWEEN": op = .match(.between)
            case "LIKE": throw error("LIKE isn't supported; use MATCHES", at: opToken)
            default:
                let at = opToken.kind == .end || opToken.kind == .disabledEnd ? keyToken : opToken
                throw error("Expected an operator after \(source(keyToken))", at: at)
            }
        }
        let opText = Self.keyword(opToken) ?? source(opToken)
        let match: MatchKind = if case .match(let m) = op { m } else { .is }
        let allowed = field?.allowedMatches ?? [.is]
        guard allowed.contains(match) else {
            throw error("‘\(opText)’ can't be used with \(keyName)", at: opToken)
        }
        advance()
        try parseModifiers()

        // Value.
        var condition: FilterExpression
        if let field {
            var c = FilterCondition(field: field, match: match, value: "", key: key, isEnabled: !disabled)
            if match == .between {
                let bounds = try parseBetween(opToken)
                c.value = bounds.0
                c.upperValue = bounds.1
            } else {
                let valueToken = try current()
                c.value = try parseValue(after: opToken, opText, field: field, match: match)
                if let problem = conditionProblem(c) { throw error(problem, at: valueToken) }
            }
            condition = .condition(FilterNormaliser.canonical(c))
        } else {
            let t = try current()
            guard case .string(let name) = t.kind else {
                if Self.value(t) == nil { throw error("Expected a value after \(opText)", at: opToken) }
                throw error("Put the saved filter's name in quotes", at: t)
            }
            advance()
            condition = .link(try resolve(name, at: t))
        }
        if case .notEqual = op { condition = .not(condition) }
        return condition
    }

    /// `[c]`, `[d]`, `[cd]` after an operator: accepted and ignored (ES §6.1).
    mutating func parseModifiers() throws(PredicateParseError) {
        guard tokens[pos].kind == .symbol("[") else { return }
        let open = tokens[pos]
        advance()
        let t = try current()
        guard case .word(let w) = t.kind, !w.isEmpty, w.lowercased().allSatisfy({ $0 == "c" || $0 == "d" })
        else { throw error("Expected [c], [d] or [cd]", at: open) }
        advance()
        guard try current().kind == .symbol("]") else { throw error("Expected [c], [d] or [cd]", at: open) }
        advance()
    }

    static func value(_ t: PredicateToken) -> String? {
        switch t.kind {
        case .string(let s), .number(let s): s
        case .word(let w) where keyword(t) == nil: w
        default: nil
        }
    }

    mutating func parseValue(
        after opToken: PredicateToken, _ opText: String, field: FilterField, match: MatchKind
    ) throws(PredicateParseError) -> String {
        let t = try current()
        guard var v = Self.value(t) else { throw error("Expected a value after \(opText)", at: opToken) }
        // `log` compares messageType as a number: 0 default, 1 info, 2 debug, 16 error, 17 fault.
        if field == .type, match != .regex, case .number(let n) = t.kind {
            v = ["0": "default", "1": "info", "2": "debug", "16": "error", "17": "fault"][n] ?? n
        }
        advance()
        return v
    }

    mutating func parseBetween(_ opToken: PredicateToken) throws(PredicateParseError) -> (String, String) {
        let expected = error(#"Expected {"HH:mm", "HH:mm"} after BETWEEN"#, at: opToken)
        guard try current().kind == .symbol("{") else { throw expected }
        advance()
        guard let lower = Self.value(try current()) else { throw expected }
        advance()
        guard try current().kind == .symbol(",") else { throw expected }
        advance()
        guard let upper = Self.value(try current()) else { throw expected }
        advance()
        guard try current().kind == .symbol("}") else { throw expected }
        advance()
        return (lower, upper)
    }

    func resolve(_ name: String, at t: PredicateToken) throws(PredicateParseError) -> UUID {
        if name.hasPrefix("<missing:"), name.hasSuffix(">"),
           let id = UUID(uuidString: String(name.dropFirst("<missing:".count).dropLast())) {
            return id
        }
        switch linkForName(name) {
        case .found(let id): return id
        case .notFound: throw error("No saved filter named ‘\(name)’", at: t)
        case .wouldLoop: throw error("This would make ‘\(name)’ include itself", at: t)
        }
    }
}
