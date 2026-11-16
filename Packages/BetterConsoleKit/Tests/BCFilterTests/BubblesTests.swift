import Foundation
import Testing
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
