import Foundation
import Testing
@testable import BCFilter

@Suite struct PredicateParserTests {
    private static let noiseID = UUID()
    private static let selfID = UUID()

    private func c(
        _ field: FilterField, _ match: MatchKind, _ value: String, key: String? = nil,
        upper: String? = nil, enabled: Bool = true
    ) -> FilterExpression {
        .condition(FilterCondition(
            field: field, match: match, value: value, key: key, upperValue: upper,
            isEnabled: enabled))
    }

    private func lookup(_ name: String) -> LinkLookup {
        switch name {
        case "Noise Exclusions": .found(Self.noiseID)
        case "Self": .wouldLoop
        default: .notFound
        }
    }

    private func parse(_ text: String) -> Result<FilterExpression?, PredicateParseError> {
        PredicateParser.parse(text, linkForName: lookup)
    }

    /// The tree, or nil with the error recorded.
    private func tree(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) -> FilterExpression?? {
        switch parse(text) {
        case .success(let e): return .some(e)
        case .failure(let error):
            Issue.record("\(error.message) at ‘\(text[error.range])’ in:\n\(text)", sourceLocation: sourceLocation)
            return nil
        }
    }

    /// The error's message and the text its range covers.
    private func failure(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) -> (message: String, at: String)? {
        switch parse(text) {
        case .success(let e):
            Issue.record("Parsed as \(String(describing: e))", sourceLocation: sourceLocation)
            return nil
        case .failure(let error):
            return (error.message, String(text[error.range]))
        }
    }

    private let a = FilterExpression.condition(FilterCondition(field: .process, match: .is, value: "a"))
    private let b = FilterExpression.condition(FilterCondition(field: .process, match: .is, value: "b"))
    private let d = FilterExpression.condition(FilterCondition(field: .process, match: .is, value: "d"))
    private var off: FilterExpression { c(.process, .is, "off", enabled: false) }

    // MARK: Round trip

    @Test func roundTripsWriterOutput() {
        var g = RandomFilterTrees(seed: 20_261_116)
        var fields = Set<FilterField>(), matches = Set<MatchKind>()
        var kinds = Set<String>()
        func visit(_ e: FilterExpression) {
            switch e {
            case .condition(let c):
                fields.insert(c.field)
                matches.insert(c.match)
                if !c.isEnabled { kinds.insert("disabled") }
            case .link(let id): kinds.insert(g.names[id] == nil ? "missing link" : "link")
            case .all(let xs):
                kinds.insert(xs.isEmpty ? "empty" : xs.count == 1 ? "one-member" : "all")
                xs.forEach(visit)
            case .any(let xs):
                kinds.insert(xs.isEmpty ? "empty" : xs.count == 1 ? "one-member" : "any")
                xs.forEach(visit)
            case .not(let x):
                switch x {
                case .any: kinds.insert("none of")
                case .all: kinds.insert("not all of")
                case .not: kinds.insert("not not")
                default: kinds.insert("not")
                }
                visit(x)
            }
        }
        for i in 0..<500 {
            let t = g.tree()
            t.map(visit)
            let text = PredicateWriter.write(t, nameForLink: g.nameForLink).text
            switch PredicateParser.parse(text, linkForName: g.linkForName) {
            case .success(let parsed):
                #expect(parsed == FilterNormaliser.normalised(t), "tree \(i):\n\(text)")
                #expect(PredicateWriter.write(parsed, nameForLink: g.nameForLink).text == text, "tree \(i)")
            case .failure(let error):
                Issue.record("tree \(i): \(error.message) at ‘\(text[error.range])’ in:\n\(text)")
            }
        }
        #expect(fields == Set(FilterField.allCases))
        #expect(matches == Set(MatchKind.allCases))
        #expect(kinds == [
            "disabled", "link", "missing link", "empty", "one-member", "all", "any", "none of",
            "not all of", "not not", "not",
        ])
    }

    @Test func writerLayouts() {
        // `(` at the end of a line followed by `//` lines, `)` alone on a line, members
        // indented 5 spaces per level.
        #expect(tree("""
            process ==[c] "a"
            AND (
                 // process ==[c] "off"
                 OR process ==[c] "b")
            """) == .all([a, .any([off, b])]))
        #expect(tree("""
            process ==[c] "a"
            AND (process ==[c] "b"
                 // OR process ==[c] "off"
            )
            """) == .all([a, .any([b, off])]))
        // `NOT (` with one `//` line reads as NOT of the disabled condition.
        #expect(tree("""
            process ==[c] "a"
            AND NOT (
                 // process ==[c] "off"
            )
            """) == .all([a, .not(off)]))
        // TRUEPREDICATE as an operand.
        #expect(tree("""
            process ==[c] "a"
            OR TRUEPREDICATE
            """) == .any([a, .all([])]))
        // Escapes.
        #expect(tree(#"eventMessage ==[c] "a\\b\"c\nd\re\tf""#)
            == c(.message, .is, "a\\b\"c\nd\re\tf"))
        // Missing link, without asking for the name.
        let missing = UUID()
        var asked: [String] = []
        let r = PredicateParser.parse(#"filter == "<missing:\#(missing.uuidString)>""#) {
            asked.append($0)
            return .notFound
        }
        #expect(r == .success(.link(missing)))
        #expect(asked.isEmpty)
    }

    // MARK: Real-world predicates

    @Test func realWorldPredicates() {
        #expect(tree(#"subsystem == "com.apple.network" && messageType == error"#) == .all([
            c(.subsystem, .is, "com.apple.network"), c(.type, .is, "error"),
        ]))
        #expect(tree(#"process == "Safari" AND (category CONTAINS[c] "tls" OR eventMessage CONTAINS "say \"hi\"")"#)
            == .all([
                c(.process, .is, "Safari"),
                .any([c(.category, .contains, "tls"), c(.message, .contains, #"say "hi""#)]),
            ]))
        #expect(tree(#"subsystem MATCHES "^com\\.apple\\.(a|b)$""#)
            == c(.subsystem, .regex, #"^com\.apple\.(a|b)$"#))
        #expect(tree(#"composedMessage BEGINSWITH "x""#) == c(.message, .startsWith, "x"))
        #expect(tree("processIdentifier != 5") == .not(c(.pid, .is, "5")))
        #expect(tree(#"NOT NOT process == "a""#) == a)
        #expect(tree("TRUEPREDICATE") == .some(nil))
    }

    @Test func aliasesAndSpellings() {
        #expect(tree("processIdentifier = 5") == c(.pid, .is, "5"))
        #expect(tree("processIdentifier => 5") == c(.pid, .greaterOrEqual, "5"))
        #expect(tree("processIdentifier =< 5") == c(.pid, .lessOrEqual, "5"))
        #expect(tree("processIdentifier <> 5") == .not(c(.pid, .is, "5")))
        #expect(tree("processIdentifier < 0500") == c(.pid, .lessThan, "500"))
        #expect(tree("threadIdentifier > 255") == c(.thread, .greaterThan, "0xff"))
        #expect(tree("threadIdentifier == 0X1F") == c(.thread, .is, "0x1f"))
        #expect(tree("activityIdentifier <= 42") == c(.activity, .lessOrEqual, "42"))
        #expect(tree("messageType >= 16") == c(.type, .greaterOrEqual, "error"))
        #expect(tree("messagetype == Fault") == c(.type, .is, "fault"))
        #expect(tree(#"messageType == "16""#) == c(.type, .is, "16"))
        #expect(tree("eventType == logEvent") == c(.eventType, .is, "logEvent"))
        #expect(tree(#"subsystem contains[cd] 'a"b'"#) == c(.subsystem, .contains, #"a"b"#))
        #expect(tree(#"subsystem ENDSWITH[d] "x""#) == c(.subsystem, .endsWith, "x"))
        #expect(tree(#"subsystem MATCHES[c] "x""#) == c(.subsystem, .regex, "x"))
        #expect(tree(#"subsystem MATCHES[cd] "x""#) == c(.subsystem, .regex, "x"))
        #expect(tree(#"sender ==[c] "x""#) == c(.library, .is, "x"))
        #expect(tree(#"processImagePath == "x" or senderImagePath == "y""#)
            == .any([c(.processPath, .is, "x"), c(.senderPath, .is, "y")]))
        #expect(tree(#"timeOfDay BETWEEN {"09:00", "18:00"}"#)
            == c(.timeOfDay, .between, "09:00", upper: "18:00"))
        #expect(tree(#"extra["user id"] CONTAINS "v""#) == c(.extra, .contains, "v", key: "user id"))
        #expect(tree(#"! process == "a" || process == "b""#) == .any([.not(a), b]))
        #expect(tree(#"filter == "Noise Exclusions""#) == .link(Self.noiseID))
        #expect(tree(#"filter != "Noise Exclusions""#) == .not(.link(Self.noiseID)))
        #expect(tree("  \n ") == .some(nil))
        // Line breaks of every kind are whitespace.
        #expect(tree("process == \"a\"\r\nAND process == \"b\"") == .all([a, b]))
    }

    @Test func groupsAndPrecedence() {
        // AND binds tighter than OR.
        #expect(tree(#"process == "a" OR process == "b" AND process == "d""#)
            == .any([a, .all([b, d])]))
        // Same-operator parentheses are flattened, others kept.
        #expect(tree(#"(process == "a" AND process == "b") AND process == "d""#) == .all([a, b, d]))
        #expect(tree(#"(process == "a" OR process == "b") AND process == "d""#)
            == .all([.any([a, b]), d]))
        #expect(tree(#"((process == "a"))"#) == a)
        #expect(tree(#"NOT (process == "a")"#) == .not(a))
        #expect(tree(#"NOT (process == "a" OR process == "b")"#) == .not(.any([a, b])))
        #expect(tree(#"NOT NOT (process == "a" AND process == "b") AND process == "d""#)
            == .all([a, b, d]))
        #expect(tree(#"NOT TRUEPREDICATE"#) == .some(nil))
        // Groups of nothing but TRUEPREDICATE are TRUEPREDICATE, at the top level too.
        #expect(tree("TRUEPREDICATE\nOR TRUEPREDICATE") == .some(nil))
        #expect(tree("TRUEPREDICATE AND (TRUEPREDICATE OR TRUEPREDICATE)") == .some(nil))
        #expect(tree(#"TRUEPREDICATE AND TRUEPREDICATE OR process == "a""#) == .any([.all([]), a]))
        #expect(tree(#"process == "a" AND (TRUEPREDICATE AND TRUEPREDICATE)"#) == .all([a, .all([])]))
    }

    // MARK: Errors

    @Test func errorsHaveRangesAndMessages() {
        func expect(_ text: String, _ message: String, at: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let f = failure(text, sourceLocation: sourceLocation)
            #expect(f?.message == message, sourceLocation: sourceLocation)
            #expect(f?.at == at, sourceLocation: sourceLocation)
        }
        expect("process ==", "Expected a value after ==", at: "==")
        expect(#"(processIdentifier >= ) AND process == "a""#, "Expected a value after >=", at: ">=")
        expect("process CONTAINS[c]\nAND process == \"a\"", "Expected a value after CONTAINS", at: "CONTAINS")
        expect(#"banana == "x""#, "Unknown key ‘banana’", at: "banana")
        expect(#"process == "a" AND procss == "b""#,
               "Unknown key ‘procss’. Did you mean ‘process’?", at: "procss")
        expect(#"process LIKE "a*""#, "LIKE isn't supported; use MATCHES", at: "LIKE")
        expect(#"process == "a" AND WHEN"#, "Reserved for a future version", at: "WHEN")
        expect(#"if process == "a""#, "Reserved for a future version", at: "if")
        expect(#"process == then"#, "Reserved for a future version", at: "then")
        expect(#"process < "a""#, "‘<’ can't be used with process", at: "<")
        expect(#"processIdentifier CONTAINS "5""#, "‘CONTAINS’ can't be used with processIdentifier", at: "CONTAINS")
        expect(#"timeOfDay == "09:00""#, "‘==’ can't be used with timeOfDay", at: "==")
        expect(#"composedMessage BETWEEN {"a", "b"}"#, "‘BETWEEN’ can't be used with eventMessage", at: "BETWEEN")
        expect("process == \"a\"\n// hello there", "Only a disabled condition can follow // on its own line",
               at: "// hello there")
        expect(#"process == "a" // note"#, "Only a disabled condition can follow // on its own line",
               at: "// note")
        expect(#"process == "a" subsystem == "b""#, "Expected AND or OR", at: "subsystem")
        expect(#"(process == "a" OR process == "b""#, "Unclosed parenthesis", at: "(")
        expect(#"filter == "Nope""#, "No saved filter named ‘Nope’", at: #""Nope""#)
        expect(#"process == "a" OR filter == "Self""#, "This would make ‘Self’ include itself", at: #""Self""#)
        expect("process == \"a\"\n// OR process == \"b\"\nAND process == \"d\"",
               "This line says OR but its group uses AND", at: "OR")
        // Errors are reported in text order.
        expect(#"banana == "x" AND process LIKE "y""#, "Unknown key ‘banana’", at: "banana")
        // Other syntax errors.
        expect(#"process == "a"#, "Unterminated string", at: #""a"#)
        expect(#"process == "a")"#, "This ) has no matching (", at: ")")
        expect(#"process == "a" AND"#, "Expected a condition after AND", at: "AND")
        expect("()", "Expected a condition after (", at: "(")
        expect(#"process "a""#, "Expected an operator after process", at: #""a""#)
        expect(#"process == "a" # b"#, "Unexpected character ‘#’", at: "#")
    }

    @Test func didYouMean() {
        let f = failure(#"subsytem == "x""#)
        #expect(f?.message == "Unknown key ‘subsytem’. Did you mean ‘subsystem’?")
        #expect(f?.at == "subsytem")
        #expect(failure(#"MESSAGETYP == "x""#)?.message == "Unknown key ‘MESSAGETYP’. Did you mean ‘messageType’?")
        // Too far from every key: no suggestion.
        #expect(failure(#"subsytsemm == "x""#)?.message == "Unknown key ‘subsytsemm’")
    }

    // MARK: Disabled lines (ES §13.2)

    @Test func disabledLineRules() {
        // Joined at its position, with or without a connector.
        #expect(tree("process == \"a\"\n// AND process == \"off\"") == .all([a, off]))
        #expect(tree("// process == \"off\"\nAND process == \"a\"") == .all([off, a]))
        #expect(tree("// process == \"off\"") == off)
        // It stays in the group whose lines surround it.
        #expect(tree("""
            process == "a"
            AND (process == "b"
                 // OR process == "off"
                 OR process == "d")
            """) == .all([a, .any([b, off, d])]))
        #expect(tree("process == \"a\"\n// OR process == \"off\"") == .any([a, off]))
        // A group of disabled lines takes its operator from their connectors; AND without one.
        #expect(tree("// process == \"a\"\n// OR process == \"off\"")
            == .any([c(.process, .is, "a", enabled: false), off]))
        #expect(tree("// process == \"a\"\n// process == \"off\"")
            == .all([c(.process, .is, "a", enabled: false), off]))
        // Indentation doesn't matter.
        #expect(tree("process == \"a\"\n        // AND   process == \"off\"") == .all([a, off]))
        // Mixed operators without parentheses: the line joins by its connector, as AND/OR do.
        #expect(tree("process == \"a\"\nOR process == \"b\"\n// AND process == \"off\"\nAND process == \"d\"")
            == .any([a, .all([b, off, d])]))

        let onlyDisabled = "Only a disabled condition can follow // on its own line"
        // No NOT on a disabled line.
        #expect(failure("process == \"a\"\n// AND NOT process == \"b\"")?.message == onlyDisabled)
        #expect(failure("// process != \"b\"")?.message == onlyDisabled)
        #expect(failure("// (process == \"b\")")?.message == onlyDisabled)
        #expect(failure("// filter == \"Noise Exclusions\"")?.message == onlyDisabled)
        #expect(failure("// TRUEPREDICATE")?.message == onlyDisabled)
        // One condition per line.
        let two = failure("// process == \"a\" AND process == \"b\"")
        #expect(two?.message == onlyDisabled)
        #expect(two?.at == "// process == \"a\" AND process == \"b\"")
        // The parenthesis after a disabled condition belongs on the next line.
        #expect(failure("(process == \"a\"\n// OR process == \"b\")")?.message == onlyDisabled)
        // A typo in the key still gets a suggestion.
        #expect(failure("// procss == \"a\"")?.message == "Unknown key ‘procss’. Did you mean ‘process’?")
        // Connector mismatch, also when only disabled lines set the operator.
        let mismatch = failure("process == \"a\"\nAND (process == \"b\"\n     // AND process == \"off\"\n     OR process == \"d\")")
        #expect(mismatch?.message == "This line says AND but its group uses OR")
        #expect(mismatch?.at == "AND")
        #expect(failure("// OR process == \"a\"\n// AND process == \"b\"")?.message
            == "This line says AND but its group uses OR")
        // A connector must be followed by a condition, not a disabled line.
        #expect(failure("process == \"a\" AND\n// process == \"b\"")?.message == "Expected a condition after AND")
    }

    /// With AND and OR mixed and no parentheses, a disabled line belongs to the group whose
    /// lines surround it: the AND chain it sits inside, or the top OR group between chains.
    @Test func disabledLinesInMixedSequences() {
        // Inside the chain `b AND d`: joins it, saying AND or nothing.
        #expect(tree("process == \"a\"\nOR process == \"b\"\n// process == \"off\"\nAND process == \"d\"")
            == .any([a, .all([b, off, d])]))
        let inChain = failure("process == \"a\"\nOR process == \"b\"\n// OR process == \"off\"\nAND process == \"d\"")
        #expect(inChain?.message == "This line says OR but its group uses AND")
        #expect(inChain?.at == "OR")
        // Between chains: joins the OR group, saying OR or nothing.
        #expect(tree("process == \"a\"\nAND process == \"b\"\n// OR process == \"off\"\nOR process == \"d\"")
            == .any([.all([a, b]), off, d]))
        #expect(tree("process == \"a\"\nAND process == \"b\"\n// process == \"off\"\nOR process == \"d\"")
            == .any([.all([a, b]), off, d]))
        let between = failure("process == \"a\"\nAND process == \"b\"\n// AND process == \"off\"\nOR process == \"d\"")
        #expect(between?.message == "This line says AND but its group uses OR")
        #expect(between?.at == "AND")
    }

    /// Inserting a disabled line anywhere either is an error or leaves what the filter matches
    /// unchanged.
    @Test func disabledLinesNeverChangeWhatMatches() {
        func enabledOnly(_ e: FilterExpression?) -> FilterExpression? {
            func strip(_ e: FilterExpression) -> FilterExpression? {
                switch e {
                case .condition(let c): return c.isEnabled ? e : nil
                case .link: return e
                case .all(let xs): return .all(xs.compactMap(strip))
                case .any(let xs): return .any(xs.compactMap(strip))
                case .not(let x): return strip(x).map(FilterExpression.not)
                }
            }
            return FilterNormaliser.normalised(e.flatMap(strip))
        }
        let texts = [
            "process == \"a\"\nOR process == \"b\"\nAND process == \"d\"",
            "process == \"a\"\nAND process == \"b\"\nOR process == \"d\"\nAND process == \"a\"",
            "process == \"a\"\nAND (process == \"b\"\nOR process == \"d\")\nOR process == \"b\"",
            "process == \"a\"\nOR process == \"b\"",
            "process == \"a\"\nAND process == \"b\"",
        ]
        var checked = 0
        for text in texts {
            guard case .success(let base) = parse(text) else { Issue.record("\(text)"); continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for at in 0...lines.count {
                for connector in ["", "AND ", "OR "] {
                    var withLine = lines.map(String.init)
                    withLine.insert("// \(connector)process == \"off\"", at: at)
                    let edited = withLine.joined(separator: "\n")
                    if case .success(let e) = parse(edited) {
                        #expect(enabledOnly(e) == enabledOnly(base), "\(edited)")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked > 20)
    }

    // MARK: Deep input

    private final class Box<T>: @unchecked Sendable { var value: T? }

    /// Runs `body` on a thread with a 512 KB stack.
    private func onSmallStack<T>(_ body: @escaping @Sendable () -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        return box.value!
    }

    @Test func deepNestingIsAnErrorNotACrash() {
        let deep = String(repeating: "(", count: 10_000) + #"process == "a""#
            + String(repeating: ")", count: 10_000)
        let r = onSmallStack { () -> (String, Int)? in
            guard case .failure(let e) = PredicateParser.parse(deep, linkForName: { _ in .notFound })
            else { return nil }
            return (e.message, deep.distance(from: deep.startIndex, to: e.range.lowerBound)
                * 1000 + deep[e.range].count)
        }
        // The 201st `(`.
        #expect(r?.0 == "Too deeply nested")
        #expect(r?.1 == 200 * 1000 + 1)
        // 200 levels still parse.
        let ok = String(repeating: "(", count: 200) + #"process == "a""# + String(repeating: ")", count: 200)
        let parsed = onSmallStack { PredicateParser.parse(ok, linkForName: { _ in .notFound }) }
        #expect(parsed == .success(a))
    }

    @Test func longNotRunsDontRecurse() {
        let even = String(repeating: "NOT ", count: 100_000) + #"process == "a""#
        let odd = "! " + even
        let a = self.a
        #expect(onSmallStack { PredicateParser.parse(even, linkForName: { _ in .notFound }) } == .success(a))
        #expect(onSmallStack { PredicateParser.parse(odd, linkForName: { _ in .notFound }) } == .success(.not(a)))
    }

    // MARK: Characters and escapes

    @Test func multiScalarText() {
        // A combining accent is part of the word.
        let key = "cafe\u{301}"
        let f = failure("\(key) == \"x\"")
        #expect(f?.message == "Unknown key ‘\(key)’")
        #expect(f?.at == key)
        // An invalid character's range covers the whole emoji, ZWJ sequence included.
        let coder = "🧑\u{200D}💻"
        let g = failure("process == \"a\" AND \(coder)")
        #expect(g?.message == "Unexpected character ‘\(coder)’")
        #expect(g?.at == coder)
    }

    @Test func escapesMatchNSPredicate() {
        // `"com\\.apple"` is `com\.apple`; `"com\.apple"` is `com.apple`, as in NSPredicate.
        #expect(tree(#"subsystem == "com\\.apple""#) == c(.subsystem, .is, #"com\.apple"#))
        #expect(tree(#"subsystem == "com\.apple""#) == c(.subsystem, .is, "com.apple"))
        #expect(tree(#"process == "\u00fc\u00FC""#) == c(.process, .is, "üü"))
        #expect(tree(#"process == "\uD83D\uDC1E""#) == c(.process, .is, "🐞"))
        #expect(tree(#"process == "\'\q""#) == c(.process, .is, "'q"))
        #expect(failure(#"process == "\u12""#)?.message == "Expected four hex digits after \\u")
        #expect(failure(#"process == "\uD83D""#)?.message == "Expected four hex digits after \\u")
    }

    // MARK: Performance

    @Test func largeInputIsFast() {
        let text = (0..<2_000).map { #"process == "p\#($0)""# }.joined(separator: "\nOR ")
        let clock = ContinuousClock()
        var result: Result<FilterExpression?, PredicateParseError>?
        let elapsed = clock.measure { result = parse(text) }
        guard case .success(.any(let xs))? = result else {
            Issue.record("Didn't parse as one Any of group")
            return
        }
        #expect(xs.count == 2_000)
        #expect(elapsed < .milliseconds(100), "took \(elapsed)")
    }

    /// R13: ranges for text in any layout, keyed by node path like the writer's.
    @Test func parseWithRangesMapsNodesInRawText() throws {
        let id = UUID()
        let text = """
            process  ==  "a"   AND   NOT   ( category == "x"  ||  filter == "Noise" )
            //   AND   processIdentifier > 5
            """
        let parsed = try PredicateParser.parseWithRanges(text, linkForName: { _ in .found(id) }).get()
        var off = FilterCondition(field: .pid, match: .greaterThan, value: "5")
        off.isEnabled = false
        #expect(parsed.expression == .all([
            .condition(FilterCondition(field: .process, match: .is, value: "a")),
            .not(.any([.condition(FilterCondition(field: .category, match: .is, value: "x")), .link(id)])),
            .condition(off),
        ]))
        let t = parsed.text
        func at(_ path: NodePath) -> String? { t.nodeRanges[path].map { String(text[$0]) } }
        #expect(t.text == text)
        #expect(at([0]) == #"process  ==  "a""#)
        #expect(at([1]) == #"category == "x"  ||  filter == "Noise""#)
        #expect(at([1, 0]) == at([1]))
        #expect(at([1, 0, 1]) == #"filter == "Noise""#)
        #expect(at([2]) == "processIdentifier > 5")
        #expect(at([])?.hasPrefix("process") == true)
        #expect(t.appOnlyRanges.map { String(text[$0]) } == [#"filter == "Noise""#, "processIdentifier > 5"])
        // Errors are still errors.
        if case .success = PredicateParser.parseWithRanges("process ==", linkForName: { _ in .notFound }) {
            Issue.record("expected an error")
        }
    }
}

extension PredicateParserTests {
    /// `log` accepts hex for processIdentifier and activityIdentifier; they read as decimal.
    @Test func hexPIDAndActivity() {
        #expect(tree("processIdentifier == 0x1F4") == .some(c(.pid, .is, "500")))
        #expect(tree("processIdentifier > 0x10") == .some(c(.pid, .greaterThan, "16")))
        #expect(tree("activityIdentifier == 0xff") == .some(c(.activity, .is, "255")))
        #expect(tree("activityIdentifier <= 0XFF") == .some(c(.activity, .lessOrEqual, "255")))
        // Decimal is unchanged; a value too large for a PID stays as written (a value problem).
        #expect(tree("processIdentifier == 42") == .some(c(.pid, .is, "42")))
        #expect(tree("processIdentifier == 0x1FFFFFFFF") == .some(c(.pid, .is, "0x1FFFFFFFF")))
    }

    /// One depth cap for every tree (FilterFile.maxDepth, counted as FilterFile counts it):
    /// text nested deeper is "Too deeply nested" at the condition that goes past it.
    @Test func treeDepthCapMatchesFilterFile() {
        // `NOT (a OR NOT (b OR …))`: every level adds two tree levels (.not, .any).
        func nested(_ levels: Int) -> String {
            var s = #"process == "x""#
            for i in 0..<levels { s = #"NOT (process == "p\#(i)" OR \#(s))"# }
            return s
        }
        // 15 levels: 31 tree levels with the innermost condition.
        let ok = nested(15)
        guard case .success(let e) = parse(ok) else {
            Issue.record("15 levels should parse")
            return
        }
        #expect(e.map(FilterFile.depth) == 31)
        // 16 levels: 33 tree levels, one past the cap; the error is at the first condition
        // past it (the innermost group's first member).
        let deep = nested(16)
        let r = failure(deep)
        #expect(r?.message == "Too deeply nested")
        #expect(r?.at == #"process == "p0""#)
        // Exactly 32: the innermost condition replaced by a group of two.
        let thirtyTwo = nested(15).replacingOccurrences(of: #"process == "x""#, with: #"(process == "x" AND process == "y")"#)
        if case .success(let e) = parse(thirtyTwo) { #expect(e.map(FilterFile.depth) == 32) } else {
            Issue.record("32 levels should parse")
        }
    }
}
