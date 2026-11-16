import Foundation
import Testing
@testable import BCFilter

@Suite struct PredicateSyntaxTests {
    private func spans(_ text: String) -> [(String, PredicateSyntax.Role)] {
        PredicateSyntax.spans(in: text).map { (String(text[$0.range]), $0.role) }
    }

    @Test func keysKeywordsOperatorsStringsAndNumbers() {
        let s = spans(#"process ==[c] "DuckDuckGo" AND processIdentifier > 500"#)
        #expect(s.map(\.0) == ["process", "==", "[", "c", "]", #""DuckDuckGo""#, "AND", "processIdentifier", ">", "500"])
        // `[c]` reads as part of the operator.
        #expect(s.map(\.1) == [.key, .operator, .operator, .operator, .operator, .string, .keyword, .key, .operator, .number])
    }

    @Test func appOnlyKeysAndLinksAreKeys() {
        let s = spans(#"timeOfDay BETWEEN {"09:00", "18:00"} OR extra["k"] == "v" OR filter == "Noise""#)
        let keys = s.filter { $0.1 == .key }.map(\.0)
        #expect(keys == ["timeOfDay", "extra", "filter"])
        #expect(s.contains { $0.0 == "BETWEEN" && $0.1 == .keyword })
    }

    @Test func keysAndKeywordsIgnoreCase() {
        let s = spans(#"eventmessage contains "x" and not composedMessage == "y""#)
        #expect(s.map(\.1) == [.key, .keyword, .string, .keyword, .keyword, .key, .operator, .string])
    }

    /// Bare values (`error`) and unknown words get no colour.
    @Test func bareValuesAreValues() {
        let s = spans("messageType >= error")
        #expect(s.map(\.1) == [.key, .operator, .value])
    }

    /// A `//` line is one disabled-line span covering the whole line, plus the spans inside.
    @Test func disabledLinesCoverTheWholeLine() {
        let text = "process == \"a\"\n// AND processIdentifier > 500\nAND subsystem == \"b\""
        let lines = PredicateSyntax.spans(in: text).filter { $0.role == .disabledLine }
        #expect(lines.map { String(text[$0.range]) } == ["// AND processIdentifier > 500"])
        #expect(spans(text).contains { $0.0 == "processIdentifier" && $0.1 == .key })
    }

    @Test func disabledLineAtTheEndOfTheText() {
        let text = "process == \"a\"\n// AND processIdentifier > 500"
        let lines = PredicateSyntax.spans(in: text).filter { $0.role == .disabledLine }
        #expect(lines.map { String(text[$0.range]) } == ["// AND processIdentifier > 500"])
    }

    /// Text that doesn't lex still gets colour up to and after the problem.
    @Test func invalidTextIsSkipped() {
        let s = spans(#"process == "unterminated"#)
        #expect(s.map(\.1) == [.key, .operator])
        let t = spans("process == § AND subsystem == \"x\"")
        #expect(t.map(\.0) == ["process", "==", "AND", "subsystem", "==", "\"x\""])
    }

    @Test func emptyText() {
        #expect(PredicateSyntax.spans(in: "").isEmpty)
    }
}
