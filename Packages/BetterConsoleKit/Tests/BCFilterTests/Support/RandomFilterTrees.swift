import Foundation
@testable import BCFilter

/// SplitMix64: a small seeded generator, so a failing tree can be reproduced from its seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Seeded random filter trees covering every field, every match a field allows, every group
/// kind (including empty and one-member groups, None of, Not all of and NOT NOT), disabled
/// conditions and links (named and missing), with values that need escaping.
struct RandomFilterTrees {
    /// Links that have a name: `nameForLink` and `linkForName` resolve them.
    let names: [UUID: String]
    /// Links to filters that no longer exist: `nameForLink` returns nil.
    let missing: [UUID]
    private var rng: SeededGenerator

    init(seed: UInt64) {
        rng = SeededGenerator(seed: seed)
        let linkNames = [
            "Noise Exclusions", #"Quote "q""#, #"Back\slash"#, "Two\nLines", "ü 🐞", "a) OR (b", "",
        ]
        var names: [UUID: String] = [:]
        for name in linkNames { names[Self.uuid(&rng)] = name }
        self.names = names
        missing = [Self.uuid(&rng), Self.uuid(&rng)]
    }

    func nameForLink(_ id: UUID) -> String? { names[id] }

    func linkForName(_ name: String) -> LinkLookup {
        names.first { $0.value == name }.map { .found($0.key) } ?? .notFound
    }

    /// A tree, nil about one time in 40.
    mutating func tree(maxDepth: Int = 4) -> FilterExpression? {
        roll(40) ? nil : expression(depth: Int.random(in: 0...maxDepth, using: &rng))
    }

    mutating func expression(depth: Int) -> FilterExpression {
        if depth == 0 {
            return roll(7) ? link() : .condition(condition())
        }
        switch Int.random(in: 0..<10, using: &rng) {
        case 0: return .condition(condition())
        case 1: return link()
        case 2, 3, 4: return .all(members(depth: depth))
        case 5, 6, 7: return .any(members(depth: depth))
        default: return .not(expression(depth: depth - 1))
        }
    }

    private mutating func members(depth: Int) -> [FilterExpression] {
        // Mostly 1–4 members; empty groups now and then.
        let count = roll(12) ? 0 : Int.random(in: 1...4, using: &rng)
        return (0..<count).map { _ in
            expression(depth: Int.random(in: 0..<depth, using: &rng))
        }
    }

    private mutating func link() -> FilterExpression {
        roll(4) ? .link(missing.randomElement(using: &rng)!)
            : .link(names.keys.sorted { $0.uuidString < $1.uuidString }.randomElement(using: &rng)!)
    }

    mutating func condition() -> FilterCondition {
        let field = FilterField.allCases.randomElement(using: &rng)!
        let match = field.allowedMatches.randomElement(using: &rng)!
        var c = FilterCondition(field: field, match: match, value: value(field: field, match: match))
        if field == .extra { c.key = text() }
        if match == .between { c.upperValue = time() }
        c.isEnabled = !roll(5)
        // Stray key / upper value the writer ignores, so the normaliser has to drop them.
        if roll(20) { c.key = text() }
        if roll(20) { c.upperValue = time() }
        return c
    }

    private mutating func value(field: FilterField, match: MatchKind) -> String {
        if match == .regex { return pick([#"^com\.duckduckgo"#, "0x1f.*", "5.*", "err.*", #"a\\b"#, "(a|b)$", text()]) }
        switch field {
        case .pid: return pick(["500", "0500", "0", "2147483647", "2147483648", "abc", "-1", ""])
        case .activity: return pick(["42", "007", "18446744073709551615", "x", ""])
        case .thread: return pick(["0x1f", "0XAB", "255", "0", "0x", "zz", "0x00ff"])
        case .type: return pick(["Default", "info", "DEBUG", "error", "Fault", "warning", "16", ""])
        case .timeOfDay: return time()
        default: return text()
        }
    }

    private mutating func time() -> String {
        pick(["09:00", "9:05", "23:59:59", "00:00", "25:00", "", "noon"])
    }

    /// Text that needs escaping now and then: quotes, backslashes, line breaks, tabs, Unicode
    /// and things that look like syntax.
    private mutating func text() -> String {
        if roll(2) {
            return pick([
                "", "Safari", "com.apple.network", #"say "hi""#, #"back\slash"#, "line\nbreak",
                "tab\tx", "cr\rx", "crlf\r\nx", "ü", "🐞", "it's", "// not a comment",
                "a) OR (b", "AND", "TRUEPREDICATE", "  spaces  ", #"\\"#, #"\""#, "{,}",
            ])
        }
        let alphabet = Array(#"abcXYZ019 _.-"'\/()[]{}<>=!&|,üé🐞"# + "\n\t\r")
        let count = Int.random(in: 0...8, using: &rng)
        return String((0..<count).map { _ in alphabet.randomElement(using: &rng)! })
    }

    private mutating func pick(_ xs: [String]) -> String { xs.randomElement(using: &rng)! }

    /// True about one time in `n`.
    private mutating func roll(_ n: Int) -> Bool { Int.random(in: 0..<n, using: &rng) == 0 }

    private static func uuid(_ rng: inout SeededGenerator) -> UUID {
        let a = rng.next(), b = rng.next()
        func byte(_ x: UInt64, _ i: Int) -> UInt8 { UInt8(truncatingIfNeeded: x >> (8 * i)) }
        return UUID(uuid: (
            byte(a, 0), byte(a, 1), byte(a, 2), byte(a, 3), byte(a, 4), byte(a, 5), byte(a, 6),
            byte(a, 7), byte(b, 0), byte(b, 1), byte(b, 2), byte(b, 3), byte(b, 4), byte(b, 5),
            byte(b, 6), byte(b, 7)))
    }
}
