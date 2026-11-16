import Foundation
import Testing
@testable import BCFilter

@Suite struct FilterLinksTests {
    private func cond(_ v: String) -> FilterExpression {
        .condition(FilterCondition(field: .process, match: .is, value: v))
    }

    private func filter(_ name: String, _ e: FilterExpression?) -> SavedFilter {
        SavedFilter(name: name, expression: e)
    }

    @Test func linksFindsEveryDirectLinkOnce() {
        let a = UUID(), b = UUID()
        let e = FilterExpression.all([
            .link(a), cond("x"), .not(.link(b)), .any([.link(a), .all([])]),
        ])
        #expect(FilterLinks.links(in: e) == [a, b])
        #expect(FilterLinks.links(in: nil).isEmpty)
        #expect(FilterLinks.links(in: cond("x")).isEmpty)
    }

    @Test func dependentsDirect() {
        let c = filter("C", cond("c"))
        let b = filter("B", .link(c.id))
        let other = filter("O", cond("o"))
        #expect(FilterLinks.dependents(of: c.id, in: [b, c, other]) == [b.id])
        #expect(FilterLinks.dependents(of: other.id, in: [b, c, other]).isEmpty)
    }

    @Test func dependentsIndirect() {
        let c = filter("C", cond("c"))
        let b = filter("B", .not(.link(c.id)))
        let a = filter("A", .any([cond("a"), .link(b.id)]))
        #expect(FilterLinks.dependents(of: c.id, in: [a, b, c]) == [a.id, b.id])
        #expect(FilterLinks.dependents(of: b.id, in: [a, b, c]) == [a.id])
        #expect(FilterLinks.dependents(of: a.id, in: [a, b, c]).isEmpty)
    }

    @Test func dependentsDiamond() {
        let d = filter("D", cond("d"))
        let b = filter("B", .link(d.id))
        let c = filter("C", .link(d.id))
        let a = filter("A", .all([.link(b.id), .link(c.id)]))
        #expect(FilterLinks.dependents(of: d.id, in: [a, b, c, d]) == [a.id, b.id, c.id])
    }

    /// An existing loop doesn't hang, and a filter never lists itself.
    @Test func dependentsThroughAnExistingLoop() {
        let aID = UUID(), bID = UUID()
        let a = SavedFilter(id: aID, name: "A", expression: .link(bID))
        let b = SavedFilter(id: bID, name: "B", expression: .link(aID))
        #expect(FilterLinks.dependents(of: aID, in: [a, b]) == [bID])
    }

    @Test func wouldLoopSelfLink() {
        let a = filter("A", cond("a"))
        #expect(FilterLinks.wouldLoop(linking: a.id, from: a.id, in: [a]))
    }

    @Test func wouldLoopBackLink() {
        let aID = UUID()
        let b = filter("B", .link(aID))
        let a = SavedFilter(id: aID, name: "A", expression: cond("a"))
        // A → B while B → A.
        #expect(FilterLinks.wouldLoop(linking: b.id, from: a.id, in: [a, b]))
        // Indirect: C → B → A, so A → C loops too.
        let c = filter("C", .link(b.id))
        #expect(FilterLinks.wouldLoop(linking: c.id, from: a.id, in: [a, b, c]))
        // B → A already exists; B linking another unrelated filter is fine.
        let d = filter("D", cond("d"))
        #expect(!FilterLinks.wouldLoop(linking: d.id, from: b.id, in: [a, b, c, d]))
        #expect(!FilterLinks.wouldLoop(linking: a.id, from: c.id, in: [a, b, c, d]))
    }

    @Test func wouldLoopUntitledIsAlwaysFalse() {
        let a = filter("A", cond("a"))
        let b = filter("B", .link(a.id))
        #expect(!FilterLinks.wouldLoop(linking: a.id, from: nil, in: [a, b]))
        #expect(!FilterLinks.wouldLoop(linking: b.id, from: nil, in: [a, b]))
    }

    @Test func closureIsFirstReachedOrderWithoutDuplicates() {
        let d = filter("D", cond("d"))
        let c = filter("C", .link(d.id))
        let b = filter("B", .all([.link(d.id), cond("b")]))
        let e = filter("E", cond("e"))
        let library = [e, d, c, b]
        let tree = FilterExpression.any([.link(b.id), .link(c.id), .not(.link(e.id)), .link(b.id)])
        #expect(FilterLinks.closure(of: tree, in: library).map(\.name) == ["B", "D", "C", "E"])
        #expect(FilterLinks.closure(of: nil, in: library).isEmpty)
    }

    /// Missing links are skipped; a loop is followed once.
    @Test func closureSkipsMissingAndStopsAtLoops() {
        let aID = UUID(), bID = UUID()
        let a = SavedFilter(id: aID, name: "A", expression: .all([.link(bID), .link(UUID())]))
        let b = SavedFilter(id: bID, name: "B", expression: .link(aID))
        #expect(FilterLinks.closure(of: .link(aID), in: [a, b]).map(\.name) == ["A", "B"])
    }
}

extension FilterLinksTests {
    @Test func directDependentsSkipsIndirectOnesAndItself() {
        let c = filter("C", cond("c"))
        let b = filter("B", .any([.link(c.id), .not(.link(c.id))]))
        let a = filter("A", .link(b.id))
        let loop = filter("L", .link(UUID()))
        let selfLink = SavedFilter(id: loop.id, name: "L", expression: .link(loop.id))
        #expect(FilterLinks.directDependents(of: c.id, in: [a, b, c]) == [b.id])
        #expect(FilterLinks.directDependents(of: b.id, in: [a, b, c]) == [a.id])
        #expect(FilterLinks.directDependents(of: a.id, in: [a, b, c]).isEmpty)
        #expect(FilterLinks.directDependents(of: loop.id, in: [selfLink]).isEmpty)
    }
}
