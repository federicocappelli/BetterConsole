import Foundation
import Testing
@testable import BCFilter

@Suite struct FilterNormaliserTests {
    private func c(
        _ field: FilterField, _ match: MatchKind, _ value: String, key: String? = nil,
        upper: String? = nil, enabled: Bool = true
    ) -> FilterExpression {
        .condition(FilterCondition(
            field: field, match: match, value: value, key: key, upperValue: upper,
            isEnabled: enabled))
    }

    private func n(_ e: FilterExpression?) -> FilterExpression? { FilterNormaliser.normalised(e) }

    private let a = FilterExpression.condition(FilterCondition(field: .process, match: .is, value: "a"))
    private let b = FilterExpression.condition(FilterCondition(field: .process, match: .is, value: "b"))
    private let d = FilterExpression.condition(FilterCondition(field: .process, match: .is, value: "d"))

    @Test func unwrapsOneMemberGroups() {
        #expect(n(.all([a])) == a)
        #expect(n(.any([.all([.any([a])])])) == a)
        #expect(n(.all([d, .any([b])])) == .all([d, b]))
        #expect(n(.any([d, .all([.all([a, b])])])) == .any([d, .all([a, b])]))
    }

    @Test func flattensSameOperator() {
        #expect(n(.all([a, .all([b, .all([d, a])])])) == .all([a, b, d, a]))
        #expect(n(.any([.any([a, b]), d])) == .any([a, b, d]))
        // A different operator stays a group.
        #expect(n(.all([a, .any([b, d])])) == .all([a, .any([b, d])]))
        // Flattened through a one-member group of the other kind.
        #expect(n(.all([a, .any([.all([b, d])])])) == .all([a, b, d]))
    }

    @Test func notShapes() {
        #expect(n(.not(.any([a]))) == .not(a))
        #expect(n(.not(.all([a]))) == .not(a))
        #expect(n(.not(.any([a, b]))) == .not(.any([a, b])))
        #expect(n(.not(.all([a, b]))) == .not(.all([a, b])))
        #expect(n(.not(.not(a))) == a)
        #expect(n(.not(.not(.not(a)))) == .not(a))
        // NOT NOT through one-member groups.
        #expect(n(.not(.any([.not(.any([b]))]))) == b)
        #expect(n(.all([d, .not(.any([.not(.all([a, b]))]))])) == .all([d, a, b]))
        #expect(n(.any([d, .not(.not(.all([a, b])))])) == .any([d, .all([a, b])]))
    }

    @Test func emptySubtrees() {
        #expect(n(nil) == nil)
        #expect(n(.all([])) == nil)
        #expect(n(.any([])) == nil)
        #expect(n(.not(.any([]))) == nil)
        #expect(n(.not(.all([.any([]), .not(.all([]))]))) == nil)
        // Nested: `.all([])`, the tree TRUEPREDICATE reads as, never flattened away.
        #expect(n(.any([a, .any([])])) == .any([a, .all([])]))
        #expect(n(.all([a, .not(.any([]))])) == .all([a, .all([])]))
        #expect(n(.any([a, .all([.any([]), .all([])])])) == .any([a, .all([])]))
        // A same-operator group with nothing in it is one TRUEPREDICATE.
        #expect(n(.all([a, .all([.any([]), .all([])])])) == .all([a, .all([])]))
        #expect(n(.any([.all([]), .all([])])) == nil)
        // A disabled condition is not empty.
        let off = c(.process, .is, "off", enabled: false)
        #expect(n(.all([off])) == off)
        #expect(n(.not(.any([off]))) == .not(off))
    }

    @Test func canonicalValues() {
        #expect(n(c(.type, .is, "Fault")) == c(.type, .is, "fault"))
        #expect(n(c(.type, .greaterOrEqual, "ERROR")) == c(.type, .greaterOrEqual, "error"))
        #expect(n(c(.pid, .is, "0500")) == c(.pid, .is, "500"))
        #expect(n(c(.activity, .lessThan, "007")) == c(.activity, .lessThan, "7"))
        #expect(n(c(.thread, .is, "255")) == c(.thread, .is, "0xff"))
        #expect(n(c(.thread, .greaterThan, "0XAB")) == c(.thread, .greaterThan, "0xab"))
        // Invalid values stay as written (the writer quotes them).
        #expect(n(c(.pid, .is, "abc")) == c(.pid, .is, "abc"))
        #expect(n(c(.type, .is, "Warning")) == c(.type, .is, "Warning"))
        #expect(n(c(.pid, .is, "2147483648")) == c(.pid, .is, "2147483648"))
        // Regex and text values are not touched.
        #expect(n(c(.type, .regex, "Err.*")) == c(.type, .regex, "Err.*"))
        #expect(n(c(.pid, .regex, "05")) == c(.pid, .regex, "05"))
        #expect(n(c(.process, .is, "Safari")) == c(.process, .is, "Safari"))
    }

    @Test func keyAndUpperValueAsWritten() {
        #expect(n(c(.process, .is, "a", key: "k", upper: "x")) == c(.process, .is, "a"))
        #expect(n(c(.extra, .is, "v")) == c(.extra, .is, "v", key: ""))
        #expect(n(c(.timeOfDay, .between, "09:00")) == c(.timeOfDay, .between, "09:00", upper: ""))
    }

    /// The normaliser and the writer agree on every random tree, and normalising is idempotent.
    @Test func agreesWithTheWriter() {
        var g = RandomFilterTrees(seed: 7)
        for _ in 0..<500 {
            let t = g.tree()
            let normal = n(t)
            #expect(n(normal) == normal)
            #expect(PredicateWriter.write(normal, nameForLink: g.nameForLink).text
                == PredicateWriter.write(t, nameForLink: g.nameForLink).text)
        }
    }
}
