import Foundation
import Testing
import BCModel
@testable import BCFilter

private func c(_ field: FilterField, _ value: String) -> FilterCondition {
    FilterCondition(field: field, match: .is, value: value)
}
private func cx(_ field: FilterField, _ value: String) -> FilterExpression {
    .condition(c(field, value))
}
private func inc(_ field: FilterField, _ value: String) -> Bubble {
    Bubble(content: .condition(c(field, value), include: true))
}
private func exc(_ field: FilterField, _ value: String) -> Bubble {
    Bubble(content: .condition(c(field, value), include: false))
}
private func adv(_ e: FilterExpression) -> Bubble { Bubble(content: .advanced(e)) }
private func contents(_ bs: [Bubble]) -> [Bubble.Content] { bs.map(\.content) }

@Suite struct BubblesTests {
    @Test func roundTripBarShape() {
        let bubbles = [
            inc(.process, "A"), inc(.process, "B"), inc(.subsystem, "S"),
            exc(.type, "debug"), exc(.category, "noise"),
        ]
        let tree = BubbleCodec.expression(from: bubbles)
        let back = BubbleCodec.bubbles(from: tree)
        #expect(contents(back) == contents(bubbles))
    }

    @Test func writesSpecOrder() {
        let x = cx(.message, "X")
        let bubbles = [
            exc(.type, "debug"), inc(.process, "A"), adv(x), inc(.process, "B"),
        ]
        let tree = BubbleCodec.expression(from: bubbles)
        #expect(tree == .all([
            x,
            .any([cx(.process, "A"), cx(.process, "B")]),
            .not(cx(.type, "debug")),
        ]))
    }

    @Test func emptyListIsNil() {
        #expect(BubbleCodec.expression(from: []) == nil)
        #expect(BubbleCodec.bubbles(from: nil).isEmpty)
    }

    @Test func lenientReading() {
        // bare condition -> include
        #expect(contents(BubbleCodec.bubbles(from: cx(.process, "A")))
                == [.condition(c(.process, "A"), include: true)])
        // one-item all flattened
        #expect(contents(BubbleCodec.bubbles(from: .all([cx(.process, "A")])))
                == [.condition(c(.process, "A"), include: true)])
        // nested all flattened into root
        #expect(contents(BubbleCodec.bubbles(from: .all([.all([cx(.process, "A"), cx(.pid, "1")])])))
                == [.condition(c(.process, "A"), include: true),
                    .condition(c(.pid, "1"), include: true)])
        // not(condition) -> exclude
        #expect(contents(BubbleCodec.bubbles(from: .not(cx(.type, "debug"))))
                == [.condition(c(.type, "debug"), include: false)])
        // any mixing fields -> one advanced
        let mixed = FilterExpression.any([cx(.process, "A"), cx(.subsystem, "S")])
        #expect(contents(BubbleCodec.bubbles(from: .all([mixed]))) == [.advanced(mixed)])
        // not(any) -> one advanced
        let notAny = FilterExpression.not(.any([cx(.process, "A"), cx(.process, "B")]))
        #expect(contents(BubbleCodec.bubbles(from: .all([notAny]))) == [.advanced(notAny)])
        // non-all root wrapped
        #expect(contents(BubbleCodec.bubbles(from: mixed)) == [.advanced(mixed)])
        // any of one field -> includes
        #expect(contents(BubbleCodec.bubbles(from: .any([cx(.process, "A"), cx(.process, "B")])))
                == [.condition(c(.process, "A"), include: true),
                    .condition(c(.process, "B"), include: true)])
    }

    @Test func advancedSurvivesSaveReload() {
        let mixed = FilterExpression.any([cx(.process, "A"), cx(.subsystem, "S")])
        let bubbles = [adv(mixed), inc(.process, "P"), exc(.type, "debug")]
        let back = BubbleCodec.bubbles(from: BubbleCodec.expression(from: bubbles))
        #expect(contents(back) == contents(bubbles))
        #expect(back.filter { if case .advanced = $0.content { true } else { false } }.count == 1)
    }

    @Test func connectorWords() {
        let a = inc(.process, "A"), b = inc(.process, "B"), s = inc(.subsystem, "S")
        let e = exc(.process, "E"), x = adv(cx(.message, "X"))
        #expect(BubbleLayout.connector(between: a, and: b) == .or)
        #expect(BubbleLayout.connector(between: a, and: s) == .and)
        #expect(BubbleLayout.connector(between: a, and: e) == .and)
        #expect(BubbleLayout.connector(between: e, and: a) == .and)
        #expect(BubbleLayout.connector(between: x, and: a) == .and)
        #expect(BubbleLayout.connector(between: a, and: x) == .and)
    }

    @Test func layoutOrder() {
        let a = inc(.process, "A"), s = inc(.subsystem, "S"), b = inc(.process, "B")
        let e = exc(.type, "debug"), x = adv(cx(.message, "X"))
        let ordered = BubbleLayout.ordered([e, a, x, s, b])
        #expect(ordered.map(\.id) == [x, a, b, s, e].map(\.id))
    }

    @Test func addingRules() {
        let a = inc(.process, "A"), b = exc(.type, "debug")
        let list = [a, b]
        // duplicate: no-op
        #expect(BubbleEditing.adding(c(.process, "A"), include: true, to: list) == list)
        // opposite include replaces at same index
        let flipped = BubbleEditing.adding(c(.process, "A"), include: false, to: list)
        #expect(flipped.count == 2)
        #expect(flipped[0].content == .condition(c(.process, "A"), include: false))
        #expect(flipped[1] == b)
        // new appends
        let appended = BubbleEditing.adding(c(.pid, "9"), include: true, to: list)
        #expect(appended.count == 3)
        #expect(appended[2].content == .condition(c(.pid, "9"), include: true))
        #expect(Array(appended.prefix(2)) == list)
    }

    @Test func separateChildrenOnOneFieldStayAnded() {
        // all(process=A, process=B) is AND; it must not become "A or B".
        let tree1 = FilterExpression.all([cx(.process, "A"), cx(.process, "B")])
        let read1 = BubbleCodec.bubbles(from: tree1)
        #expect(contents(read1) == [
            .advanced(cx(.process, "B")), .condition(c(.process, "A"), include: true),
        ])
        #expect(contents(BubbleCodec.bubbles(from: BubbleCodec.expression(from: read1)))
                == contents(read1))
        let entryAB = makeEntry(process: "A")
        #expect(!CompiledFilter(BubbleCodec.expression(from: read1)).matches(entryAB))

        // all(any(A,B), any(C)) likewise.
        let anyC = FilterExpression.any([cx(.process, "C")])
        let tree2 = FilterExpression.all([.any([cx(.process, "A"), cx(.process, "B")]), anyC])
        let read2 = BubbleCodec.bubbles(from: tree2)
        #expect(contents(read2) == [
            .advanced(anyC),
            .condition(c(.process, "A"), include: true), .condition(c(.process, "B"), include: true),
        ])
        #expect(contents(BubbleCodec.bubbles(from: BubbleCodec.expression(from: read2)))
                == contents(read2))
    }

    // MARK: Links and disabled conditions

    @Test func linkBubblesRoundTrip() {
        let a = UUID(), b = UUID()
        let mixed = FilterExpression.any([cx(.process, "Q"), cx(.subsystem, "S")])
        let bubbles = [
            Bubble(content: .link(b, include: false)), exc(.type, "debug"),
            Bubble(content: .link(a, include: true)), inc(.process, "P"), adv(mixed),
        ]
        let tree = BubbleCodec.expression(from: bubbles)
        #expect(tree == .all([
            mixed, .any([cx(.process, "P")]), .link(a),
            .not(cx(.type, "debug")), .not(.link(b)),
        ]))
        let back = BubbleCodec.bubbles(from: tree)
        #expect(contents(back) == [
            .advanced(mixed), .condition(c(.process, "P"), include: true),
            .link(a, include: true), .condition(c(.type, "debug"), include: false),
            .link(b, include: false),
        ])
        #expect(BubbleCodec.expression(from: back) == tree)
        // Bare roots.
        #expect(contents(BubbleCodec.bubbles(from: .link(a))) == [.link(a, include: true)])
        #expect(contents(BubbleCodec.bubbles(from: .not(.link(a)))) == [.link(a, include: false)])
    }

    @Test func disabledBubbleKeepsGroupAndConnector() {
        var off = c(.process, "B"); off.isEnabled = false
        let a = inc(.process, "A"), d = Bubble(content: .condition(off, include: true))
        let s = inc(.subsystem, "S")
        #expect(BubbleLayout.connector(between: a, and: d) == .or)
        #expect(BubbleLayout.connector(between: d, and: a) == .or)
        let list = [a, s, d]
        let ordered = BubbleLayout.ordered(list)
        #expect(ordered.map(\.id) == [a, d, s].map(\.id))
        let tree = BubbleCodec.expression(from: list)
        #expect(tree == .all([
            .any([cx(.process, "A"), .condition(off)]), .any([cx(.subsystem, "S")]),
        ]))
        #expect(contents(BubbleCodec.bubbles(from: tree)) == contents(ordered))
        // A disabled exclude round-trips too.
        let e = Bubble(content: .condition(off, include: false))
        #expect(contents(BubbleCodec.bubbles(from: BubbleCodec.expression(from: [e])))
                == [e.content])
    }

    @Test func hideShowLeavesLinksAndDisabledAlone() {
        var off = c(.process, "A"); off.isEnabled = false
        let link = Bubble(content: .link(UUID(), include: true))
        let disabled = Bubble(content: .condition(off, include: true))
        let list = [link, disabled]
        // The same condition, enabled, is not a duplicate of the disabled one: appended.
        let added = BubbleEditing.adding(c(.process, "A"), include: true, to: list)
        #expect(added.count == 3)
        #expect(Array(added.prefix(2)) == list)
        // Opposite role does not replace the disabled one either.
        let other = BubbleEditing.adding(c(.process, "A"), include: false, to: list)
        #expect(other.count == 3)
        #expect(Array(other.prefix(2)) == list)
        // Adding a disabled condition never matches an existing bubble.
        let twice = BubbleEditing.adding(off, include: true, to: list)
        #expect(twice.count == 3)
    }

    @Test func toggleFlipsOnlyConditions() {
        let a = inc(.process, "A")
        let t = BubbleEditing.toggled(a)
        #expect(t.id == a.id)
        guard case .condition(let tc, true) = t.content else { Issue.record("not a condition"); return }
        #expect(!tc.isEnabled)
        #expect(BubbleEditing.toggled(t).content == a.content)
        let x = adv(cx(.message, "X")), l = Bubble(content: .link(UUID(), include: false))
        #expect(BubbleEditing.toggled(x) == x)
        #expect(BubbleEditing.toggled(l) == l)
    }

    // MARK: ExpressionSummary (Advanced rule tooltip)

    @Test func summaryOfConditionsGroupsAndNot() {
        let a = FilterExpression.condition(FilterCondition(field: .process, match: .is, value: "A"))
        let b = FilterExpression.condition(
            FilterCondition(field: .message, match: .contains, value: "b"))
        let c = FilterExpression.condition(FilterCondition(field: .type, match: .is, value: "error"))
        #expect(ExpressionSummary.text(a) == #"Process is "A""#)
        #expect(ExpressionSummary.text(.all([a, b])) == #"Process is "A" and Message contains "b""#)
        #expect(ExpressionSummary.text(.any([a, b])) == #"Process is "A" or Message contains "b""#)
        // Nested groups of two or more get parentheses; a single child does not.
        #expect(ExpressionSummary.text(.all([.any([a, b]), c]))
            == #"(Process is "A" or Message contains "b") and Type is "error""#)
        #expect(ExpressionSummary.text(.any([.all([a]), .all([b, .any([a, c])])]))
            == #"Process is "A" or (Message contains "b" and (Process is "A" or Type is "error"))"#)
        #expect(ExpressionSummary.text(.not(a)) == #"not Process is "A""#)
        #expect(ExpressionSummary.text(.not(.any([a, b])))
            == #"not (Process is "A" or Message contains "b")"#)
    }

    /// An empty group imposes no constraint (as `CompiledFilter` evaluates it), whatever its kind.
    @Test func summaryOfEmptyGroups() {
        let a = FilterExpression.condition(FilterCondition(field: .process, match: .is, value: "A"))
        #expect(ExpressionSummary.text(.any([])) == "(no condition)")
        #expect(ExpressionSummary.text(.all([])) == "(no condition)")
        #expect(ExpressionSummary.text(.all([a, .any([])])) == #"Process is "A" and (no condition)"#)
        #expect(ExpressionSummary.text(.not(.any([]))) == "not (no condition)")
    }
}

extension BubblesTests {
    /// A field group whose members are all disabled imposes no constraint (ES §13.2), round
    /// trips as the same bubbles, and constrains again once one member is switched back on
    /// (on > off > on through the bar's Enable/Disable).
    @Test func fieldGroupWithEveryMemberDisabled() {
        let a = inc(.process, "A"), b = inc(.process, "B"), s = inc(.subsystem, "S")
        let inS = makeEntry(process: "Z", subsystem: "S")
        let aInS = makeEntry(process: "A", subsystem: "S")
        func matches(_ bubbles: [Bubble], _ entry: LogEntry) -> Bool {
            CompiledFilter(BubbleCodec.expression(from: bubbles)).matches(entry)
        }
        let on = [a, b, s]
        #expect(!matches(on, inS))
        #expect(matches(on, aInS))

        let off = [BubbleEditing.toggled(a), BubbleEditing.toggled(b), s]
        let tree = BubbleCodec.expression(from: off)
        var offA = c(.process, "A"), offB = c(.process, "B")
        offA.isEnabled = false
        offB.isEnabled = false
        #expect(tree == .all([.any([.condition(offA), .condition(offB)]), .any([cx(.subsystem, "S")])]))
        #expect(contents(BubbleCodec.bubbles(from: tree)) == contents(BubbleLayout.ordered(off)))
        #expect(matches(off, inS))
        #expect(!matches(off, makeEntry(process: "A", subsystem: "T")))

        let back = [BubbleEditing.toggled(off[0]), off[1], s]
        #expect(!matches(back, inS))
        #expect(matches(back, aInS))
        #expect(contents(BubbleCodec.bubbles(from: BubbleCodec.expression(from: back)))
                == contents(BubbleLayout.ordered(back)))
    }

    /// A later group on a field that already has an include group stays Advanced (separate
    /// root children are ANDed); a disabled member inside it is dropped at evaluation, never
    /// merged into the include group, and a later group of only disabled members imposes
    /// nothing.
    @Test func disabledMemberInALaterSameFieldGroup() {
        var offB = c(.process, "B"); offB.isEnabled = false
        let later = FilterExpression.any([.condition(offB), cx(.process, "C")])
        let tree = FilterExpression.all([.any([cx(.process, "A")]), later])
        let read = BubbleCodec.bubbles(from: tree)
        #expect(contents(read) == [.advanced(later), .condition(c(.process, "A"), include: true)])
        #expect(BubbleCodec.expression(from: read) == tree)
        // A AND (C, B switched off): nothing has two processes, and B never matches.
        for p in ["A", "B", "C"] {
            #expect(!CompiledFilter(tree).matches(makeEntry(process: p)), "\(p)")
        }

        let onlyOff = FilterExpression.any([.condition(offB)])
        let tree2 = FilterExpression.all([.any([cx(.process, "A")]), onlyOff])
        let read2 = BubbleCodec.bubbles(from: tree2)
        #expect(contents(read2) == [.advanced(onlyOff), .condition(c(.process, "A"), include: true)])
        #expect(BubbleCodec.expression(from: read2) == tree2)
        #expect(CompiledFilter(tree2).matches(makeEntry(process: "A")))
        #expect(!CompiledFilter(tree2).matches(makeEntry(process: "B")))
    }
}
