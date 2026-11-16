import Foundation
import Testing
@testable import BCFilter

@Suite struct PredicateWriterTests {
    private static let noiseID = UUID()

    private func c(
        _ field: FilterField, _ match: MatchKind, _ value: String, key: String? = nil,
        upper: String? = nil, enabled: Bool = true
    ) -> FilterExpression {
        .condition(FilterCondition(
            field: field, match: match, value: value, key: key, upperValue: upper,
            isEnabled: enabled))
    }

    private func names(_ id: UUID) -> String? {
        id == Self.noiseID ? "Noise Exclusions" : nil
    }

    private func write(_ e: FilterExpression?) -> PredicateText {
        PredicateWriter.write(e, nameForLink: names)
    }

    private func text(_ e: FilterExpression?) -> String { write(e).text }

    private func substrings(_ p: PredicateText, _ ranges: [Range<String.Index>]) -> [String] {
        ranges.map { String(p.text[$0]) }
    }

    /// The ES §8 mockup tree.
    private var mockupTree: FilterExpression {
        .all([
            c(.process, .is, "DuckDuckGo"),
            c(.type, .greaterOrEqual, "error"),
            c(.pid, .greaterThan, "500", enabled: false),
            .any([
                c(.subsystem, .regex, #"^com\.duckduckgo"#),
                c(.thread, .regex, "0x1f.*"),
            ]),
            .not(.any([c(.category, .contains, "heartbeat")])),
            .link(Self.noiseID),
        ])
    }

    @Test func canonicalLayout() {
        #expect(text(mockupTree) == """
            process ==[c] "DuckDuckGo"
            AND messageType >= error
            // AND processIdentifier > 500
            AND (subsystem MATCHES[c] "^com\\\\.duckduckgo"
                 OR threadIdentifier MATCHES[c] "0x1f.*")
            AND NOT category CONTAINS[c] "heartbeat"
            AND filter == "Noise Exclusions"
            """)
        // Writing is canonical: the same tree gives the same text.
        let rebuilt = FilterExpression.all([
            c(.process, .is, "DuckDuckGo"),
            c(.type, .greaterOrEqual, "error"),
            c(.pid, .greaterThan, "500", enabled: false),
            .any([c(.subsystem, .regex, #"^com\.duckduckgo"#), c(.thread, .regex, "0x1f.*")]),
            .not(.any([c(.category, .contains, "heartbeat")])),
            .link(Self.noiseID),
        ])
        #expect(text(rebuilt) == text(mockupTree))
    }

    @Test func emptyIsTruePredicate() {
        #expect(text(nil) == "TRUEPREDICATE")
        #expect(text(.all([])) == "TRUEPREDICATE")
        #expect(text(.any([])) == "TRUEPREDICATE")
        #expect(text(.not(.any([]))) == "TRUEPREDICATE")
        #expect(text(.not(.all([.any([])]))) == "TRUEPREDICATE")
        #expect(write(nil).appOnlyRanges.isEmpty)
        // A same-operator group with nothing in it is one TRUEPREDICATE, not one per member.
        let all2 = write(.any([.all([]), .all([])]))
        #expect(all2.text == "TRUEPREDICATE")
        #expect(all2.appOnlyRanges.isEmpty)
        let a = c(.process, .is, "a")
        #expect(text(.all([a, .all([.any([]), .any([])])])) == """
            process ==[c] "a"
            AND TRUEPREDICATE
            """)
    }

    @Test func operatorsAndLiterals() {
        #expect(text(c(.message, .contains, "x")) == #"eventMessage CONTAINS[c] "x""#)
        #expect(text(c(.library, .startsWith, "x")) == #"sender BEGINSWITH[c] "x""#)
        #expect(text(c(.processPath, .endsWith, "x")) == #"processImagePath ENDSWITH[c] "x""#)
        #expect(text(c(.senderPath, .is, "x")) == #"senderImagePath ==[c] "x""#)
        #expect(text(c(.eventType, .regex, "log.*")) == #"eventType MATCHES[c] "log.*""#)
        #expect(text(c(.pid, .is, "0500")) == "processIdentifier == 500")
        #expect(text(c(.pid, .lessThan, "7")) == "processIdentifier < 7")
        #expect(text(c(.activity, .lessOrEqual, "42")) == "activityIdentifier <= 42")
        #expect(text(c(.thread, .greaterThan, "255")) == "threadIdentifier > 0xff")
        #expect(text(c(.thread, .is, "0XAB")) == "threadIdentifier == 0xab")
        #expect(text(c(.type, .is, "Fault")) == "messageType == fault")
        #expect(text(c(.type, .lessOrEqual, "info")) == "messageType <= info")
        #expect(text(c(.type, .regex, "err.*")) == #"messageType MATCHES[c] "err.*""#)
        #expect(text(c(.pid, .regex, "5.*")) == #"processIdentifier MATCHES[c] "5.*""#)
        #expect(text(c(.timeOfDay, .between, "09:00", upper: "18:00"))
            == #"timeOfDay BETWEEN {"09:00", "18:00"}"#)
        #expect(text(c(.extra, .is, "v", key: "user id"))
            == #"extra["user id"] ==[c] "v""#)
        // A value the field can't use is still written, as a string.
        #expect(text(c(.pid, .is, "abc")) == #"processIdentifier == "abc""#)
    }

    @Test func escapes() {
        #expect(text(c(.message, .contains, #"say "hi""#))
            == #"eventMessage CONTAINS[c] "say \"hi\"""#)
        #expect(text(c(.message, .is, #"\"#)) == #"eventMessage ==[c] "\\""#)
        #expect(text(c(.extra, .is, "v", key: #"a"b\"#)) == #"extra["a\"b\\"] ==[c] "v""#)
        // A line break would end a `//` line early, so it is escaped too.
        #expect(text(c(.message, .is, "a\nb", enabled: false)) == #"// eventMessage ==[c] "a\nb""#)
        #expect(text(c(.message, .is, "a\rb\tc")) == #"eventMessage ==[c] "a\rb\tc""#)
        #expect(text(c(.extra, .is, "v", key: "k\nk", enabled: false))
            == #"// extra["k\nk"] ==[c] "v""#)
        let id = UUID()
        #expect(PredicateWriter.write(.link(id), nameForLink: { _ in "Two\nLines" }).text
            == #"filter == "Two\nLines""#)
    }

    @Test func unicode() {
        #expect(text(c(.process, .is, "ü")) == "process ==[c] \"ü\"")
        #expect(text(c(.message, .contains, "🐞")) == "eventMessage CONTAINS[c] \"🐞\"")
        let p = write(.all([c(.process, .is, "ü"), c(.timeOfDay, .between, "01:00", upper: "02:00")]))
        #expect(substrings(p, p.appOnlyRanges) == [#"timeOfDay BETWEEN {"01:00", "02:00"}"#])
        #expect(p.nodeRanges[[0]].map { String(p.text[$0]) } == "process ==[c] \"ü\"")
    }

    @Test func parenthesesOnlyWhenNeeded() {
        let a = c(.process, .is, "a"), b = c(.process, .is, "b"), d = c(.process, .is, "d")
        // Same operator: no parentheses.
        #expect(text(.all([a, .all([b, d])])) == """
            process ==[c] "a"
            AND process ==[c] "b"
            AND process ==[c] "d"
            """)
        #expect(text(.any([a, b])) == """
            process ==[c] "a"
            OR process ==[c] "b"
            """)
        // Operator changes: parentheses, members indented 5 spaces per level.
        #expect(text(.any([a, .all([b, .any([d, a])])])) == """
            process ==[c] "a"
            OR (process ==[c] "b"
                 AND (process ==[c] "d"
                      OR process ==[c] "a"))
            """)
        #expect(text(.all([.any([a, b]), d])) == """
            (process ==[c] "a"
                 OR process ==[c] "b")
            AND process ==[c] "d"
            """)
        // A single-member group needs none.
        #expect(text(.all([a, .any([b])])) == """
            process ==[c] "a"
            AND process ==[c] "b"
            """)
        #expect(text(.any([b])) == #"process ==[c] "b""#)
        // NOT shapes.
        #expect(text(.not(a)) == #"NOT process ==[c] "a""#)
        #expect(text(.not(.any([a]))) == #"NOT process ==[c] "a""#)
        #expect(text(.not(.any([a, b]))) == """
            NOT (process ==[c] "a"
                 OR process ==[c] "b")
            """)
        #expect(text(.all([d, .not(.all([a, b]))])) == """
            process ==[c] "d"
            AND NOT (process ==[c] "a"
                 AND process ==[c] "b")
            """)
        #expect(text(.not(.not(a))) == #"process ==[c] "a""#)
        #expect(text(.all([d, .not(.not(.all([a, b])))])) == """
            process ==[c] "d"
            AND process ==[c] "a"
            AND process ==[c] "b"
            """)
    }

    @Test func disabledLinesKeepTheirGroup() {
        let a = c(.process, .is, "a"), b = c(.process, .is, "b")
        let off = c(.process, .is, "off", enabled: false)
        // First line has no connector.
        #expect(text(.all([off, a])) == """
            // process ==[c] "off"
            AND process ==[c] "a"
            """)
        #expect(text(off) == #"// process ==[c] "off""#)
        // Inside a nested group, indented like its siblings with that group's connector.
        #expect(text(.all([a, .any([b, off, a])])) == """
            process ==[c] "a"
            AND (process ==[c] "b"
                 // OR process ==[c] "off"
                 OR process ==[c] "a")
            """)
        // First member disabled: the `(` stays alone on its line.
        #expect(text(.all([a, .any([off, b])])) == """
            process ==[c] "a"
            AND (
                 // process ==[c] "off"
                 OR process ==[c] "b")
            """)
        // Last member disabled: the `)` goes on its own line.
        #expect(text(.all([a, .any([b, off])])) == """
            process ==[c] "a"
            AND (process ==[c] "b"
                 // OR process ==[c] "off"
            )
            """)
        // No NOT on a disabled line: a disabled exclusion keeps its parentheses.
        #expect(text(.all([a, .not(.any([off]))])) == """
            process ==[c] "a"
            AND NOT (
                 // process ==[c] "off"
            )
            """)
        #expect(text(.all([a, .not(.any([b, off]))])) == """
            process ==[c] "a"
            AND NOT (process ==[c] "b"
                 // OR process ==[c] "off"
            )
            """)
        #expect(text(.not(.all([off, b]))) == """
            NOT (
                 // process ==[c] "off"
                 AND process ==[c] "b")
            """)
    }

    @Test func appOnlyRangesCoverTimeExtraLinkAndNumericRegex() {
        let missing = UUID()
        let p = write(.all([
            c(.process, .is, "a"),
            c(.timeOfDay, .between, "09:00", upper: "18:00"),
            c(.extra, .contains, "x", key: "k"),
            .link(Self.noiseID),
            .link(missing),
            c(.pid, .regex, "1.*"),
            c(.thread, .regex, "0x.*"),
            c(.activity, .regex, "2.*"),
            c(.type, .regex, "e.*"),
            c(.subsystem, .regex, "com.*"),
            c(.process, .is, "off", enabled: false),
            .not(c(.timeOfDay, .between, "01:00", upper: "02:00")),
        ]))
        #expect(substrings(p, p.appOnlyRanges) == [
            #"timeOfDay BETWEEN {"09:00", "18:00"}"#,
            #"extra["k"] CONTAINS[c] "x""#,
            #"filter == "Noise Exclusions""#,
            #"filter == "<missing:\#(missing.uuidString)>""#,
            #"processIdentifier MATCHES[c] "1.*""#,
            #"threadIdentifier MATCHES[c] "0x.*""#,
            #"activityIdentifier MATCHES[c] "2.*""#,
            #"messageType MATCHES[c] "e.*""#,
            #"// AND process ==[c] "off""#,
            #"timeOfDay BETWEEN {"01:00", "02:00"}"#,
        ])
        #expect(write(.all([c(.process, .is, "a"), c(.subsystem, .regex, "x")])).appOnlyRanges.isEmpty)
    }

    @Test func logPredicateDropsAppOnlyParts() {
        let r = PredicateWriter.logPredicate(mockupTree, nameForLink: names)
        // Disabled PID, thread regex and the link are removed.
        #expect(r.removed == 3)
        #expect(r.text == """
            process ==[c] "DuckDuckGo"
            AND messageType >= error
            AND subsystem MATCHES[c] "^com\\\\.duckduckgo"
            AND NOT category CONTAINS[c] "heartbeat"
            """)

        // A group left empty goes too, with its NOT.
        let r2 = PredicateWriter.logPredicate(.all([
            c(.process, .is, "a"),
            .not(.any([c(.timeOfDay, .between, "01:00", upper: "02:00"), .link(UUID())])),
            .any([c(.extra, .is, "v", key: "k")]),
        ]), nameForLink: names)
        #expect(r2.removed == 3)
        #expect(r2.text == #"process ==[c] "a""#)

        let r3 = PredicateWriter.logPredicate(.link(Self.noiseID), nameForLink: names)
        #expect(r3.removed == 1)
        #expect(r3.text == "TRUEPREDICATE")

        let r4 = PredicateWriter.logPredicate(nil, nameForLink: names)
        #expect(r4.removed == 0)
        #expect(r4.text == "TRUEPREDICATE")
    }

    @Test func notNotCollapsesThroughOneMemberGroups() {
        let a = c(.process, .is, "a"), b = c(.process, .is, "b"), d = c(.process, .is, "d")
        let t1 = FilterExpression.not(.any([.not(.any([b]))]))
        #expect(text(t1) == #"process ==[c] "b""#)
        #expect(text(t1) == text(b))
        let p1 = write(t1)
        for path: NodePath in [[], [0], [0, 0], [0, 0, 0], [0, 0, 0, 0]] {
            #expect(p1.nodeRanges[path].map { String(p1.text[$0]) } == #"process ==[c] "b""#)
        }

        let t2 = FilterExpression.all([d, .not(.any([.not(.all([a, b]))]))])
        #expect(text(t2) == """
            process ==[c] "d"
            AND process ==[c] "a"
            AND process ==[c] "b"
            """)
        #expect(text(t2) == text(.all([d, a, b])))
        let p2 = write(t2)
        #expect(p2.nodeRanges[[1, 0, 0, 0, 1]].map { String(p2.text[$0]) } == #"process ==[c] "b""#)

        // At the root, the operator comes from inside the wrappers.
        let t3 = FilterExpression.not(.all([.not(.any([a, b]))]))
        #expect(text(t3) == text(.any([a, b])))
        #expect(text(t3) == """
            process ==[c] "a"
            OR process ==[c] "b"
            """)
        // As an operand under a different operator.
        let t4 = FilterExpression.any([d, .not(.any([.not(.all([a, b]))]))])
        #expect(text(t4) == text(.any([d, .all([a, b])])))
    }

    @Test func nestedTruePredicateIsAppOnly() {
        let a = c(.process, .is, "a")
        let p = write(.any([a, .all([])]))
        #expect(p.text == """
            process ==[c] "a"
            OR TRUEPREDICATE
            """)
        #expect(substrings(p, p.appOnlyRanges) == ["TRUEPREDICATE"])
        let q = write(.all([a, .not(.any([]))]))
        #expect(substrings(q, q.appOnlyRanges) == ["TRUEPREDICATE"])
        // The whole text being TRUEPREDICATE means the same in `log`.
        #expect(write(.all([])).appOnlyRanges.isEmpty)
        #expect(write(.not(.any([.all([])]))).appOnlyRanges.isEmpty)
        #expect(write(nil).appOnlyRanges.isEmpty)
    }

    @Test func nodeRangesMapPathsToText() {
        let p = write(mockupTree)
        func at(_ path: NodePath) -> String? { p.nodeRanges[path].map { String(p.text[$0]) } }
        #expect(at([]) == p.text)
        #expect(at([0]) == #"process ==[c] "DuckDuckGo""#)
        #expect(at([1]) == "messageType >= error")
        #expect(at([2]) == "// AND processIdentifier > 500")
        #expect(at([3]) == """
            (subsystem MATCHES[c] "^com\\\\.duckduckgo"
                 OR threadIdentifier MATCHES[c] "0x1f.*")
            """)
        #expect(at([3, 0]) == #"subsystem MATCHES[c] "^com\\.duckduckgo""#)
        #expect(at([3, 1]) == #"threadIdentifier MATCHES[c] "0x1f.*""#)
        #expect(at([4]) == #"NOT category CONTAINS[c] "heartbeat""#)
        #expect(at([4, 0]) == #"category CONTAINS[c] "heartbeat""#)
        #expect(at([4, 0, 0]) == #"category CONTAINS[c] "heartbeat""#)
        #expect(at([5]) == #"filter == "Noise Exclusions""#)
        #expect(p.nodeRanges.count == 11)

        // Flattened same-operator groups cover their members.
        let a = c(.process, .is, "a"), b = c(.process, .is, "b")
        let q = write(.all([a, .all([b, a])]))
        #expect(q.nodeRanges[[1]].map { String(q.text[$0]) } == """
            process ==[c] "b"
            AND process ==[c] "a"
            """)
        #expect(q.nodeRanges[[1, 1]].map { String(q.text[$0]) } == #"process ==[c] "a""#)
        // An empty group maps to its TRUEPREDICATE.
        let e = write(.all([a, .any([])]))
        #expect(e.nodeRanges[[1]].map { String(e.text[$0]) } == "TRUEPREDICATE")
        #expect(write(nil).nodeRanges.isEmpty)
    }
}

extension PredicateWriterTests {
    /// In `log`, eventType is a numeric enum: only `==` with one of its exact names works
    /// there. Anything else is app-only: tinted, and left out by "Copy as log predicate".
    @Test func eventTypeIsLogCompatibleOnlyAsAnExactName() {
        let names = [
            "activityCreateEvent", "activityTransitionEvent", "logEvent", "signpostEvent",
            "stateEvent", "timesyncEvent", "traceEvent", "userActionEvent",
        ]
        for name in names {
            let e = c(.eventType, .is, name)
            #expect(write(e).appOnlyRanges.isEmpty, "\(name)")
            #expect(PredicateWriter.logPredicate(e, nameForLink: self.names).removed == 0, "\(name)")
        }
        let appOnly: [FilterExpression] = [
            c(.eventType, .is, "logevent"),  // wrong case
            c(.eventType, .is, "lossEvent"),  // unknown
            c(.eventType, .contains, "log"),
            c(.eventType, .startsWith, "log"),
            c(.eventType, .endsWith, "Event"),
            c(.eventType, .regex, "log.*"),
        ]
        for e in appOnly {
            let p = write(e)
            #expect(substrings(p, p.appOnlyRanges) == [p.text], "\(p.text)")
        }
        let mixed = FilterExpression.all([c(.process, .is, "a"), c(.eventType, .contains, "log")])
        let r = PredicateWriter.logPredicate(mixed, nameForLink: self.names)
        #expect(r.text == #"process ==[c] "a""#)
        #expect(r.removed == 1)
    }

    /// A condition whose value can't be used is written as it is, tinted, and left out of
    /// "Copy as log predicate".
    @Test func invalidConditionsAreAppOnly() {
        let invalid: [FilterExpression] = [
            c(.message, .regex, "("),
            c(.pid, .is, "abc"),
            c(.thread, .greaterThan, "zz"),
            c(.timeOfDay, .between, "25:00", upper: "26:00"),
        ]
        for e in invalid {
            let p = write(e)
            #expect(substrings(p, p.appOnlyRanges) == [p.text], "\(p.text)")
        }
        let tree = FilterExpression.all([c(.process, .is, "a"), c(.message, .regex, "(")])
        let r = PredicateWriter.logPredicate(tree, nameForLink: names)
        #expect(r.text == #"process ==[c] "a""#)
        #expect(r.removed == 1)
        // A valid regex on a text field stays log-compatible.
        #expect(write(c(.message, .regex, "a.*")).appOnlyRanges.isEmpty)
    }

    /// PID and Activity ID values given in hex are written in decimal.
    @Test func hexPIDAndActivityAreWrittenInDecimal() {
        #expect(text(c(.pid, .is, "0x1F4")) == "processIdentifier == 500")
        #expect(text(c(.activity, .greaterThan, "0x10")) == "activityIdentifier > 16")
        #expect(write(c(.pid, .is, "0x1F4")).appOnlyRanges.isEmpty)
    }
}
