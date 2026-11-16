import Foundation
import Testing
@testable import BCFilter

@Suite struct FilterFileTests {
    private func cond(_ f: FilterField, _ m: MatchKind, _ v: String, _ on: Bool = true) -> FilterExpression {
        .condition(FilterCondition(field: f, match: m, value: v, isEnabled: on))
    }

    private func file(
        format: String? = "betterconsole.filter", version: Int? = 1,
        id: String? = "6F1C2B3A-0000-4000-8000-000000000001", name: String? = "DDG Errors",
        expression: String? = #"{"condition":{"field":"process","match":"is","value":"X"}}"#,
        extra: String = ""
    ) -> Data {
        var parts: [String] = []
        if let format { parts.append(#""format":"\#(format)""#) }
        if let version { parts.append(#""version":\#(version)"#) }
        if let id { parts.append(#""id":"\#(id)""#) }
        if let name { parts.append(#""name":"\#(name)""#) }
        if let expression { parts.append(#""expression":\#(expression)"#) }
        if !extra.isEmpty { parts.append(extra) }
        return Data("{\(parts.joined(separator: ","))}".utf8)
    }

    private func conditionJSON(_ field: String, _ match: String, _ value: String, extra: String = "") -> String {
        #"{"condition":{"field":"\#(field)","match":"\#(match)","value":"\#(value)"\#(extra)}}"#
    }

    private func nested(nots: Int) -> String {
        String(repeating: #"{"not":"#, count: nots) + conditionJSON("process", "is", "X")
            + String(repeating: "}", count: nots)
    }

    @Test func exportImportRoundTrip() throws {
        let expr: FilterExpression = .all([
            .any([cond(.process, .is, "DuckDuckGo")]),
            .not(cond(.type, .is, "debug")),
            cond(.message, .regex, "a/b"),
        ])
        let saved = SavedFilter(id: UUID(), name: "DDG Errors", expression: expr)
        let data = try FilterFile.encode(saved)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""format" : "betterconsole.filter""#))
        #expect(json.contains(#""version" : 1"#))
        #expect(json.contains("a/b"))
        #expect(try FilterFile.decode(data) == saved)
    }

    @Test func roundTripsEveryMatchKindAndGroup() throws {
        let expr: FilterExpression = .all([
            .any([cond(.process, .contains, "a"), cond(.subsystem, .is, "b")]),
            .not(.any([cond(.category, .startsWith, "c"), cond(.message, .regex, "d+")])),
            cond(.type, .is, "debug"),
        ])
        let saved = SavedFilter(id: UUID(), name: "All", expression: expr)
        #expect(try FilterFile.decode(FilterFile.encode(saved)) == saved)
    }

    @Test func exportRejectsDisabledCondition() {
        let saved = SavedFilter(
            id: UUID(), name: "D", expression: .all([.not(cond(.process, .is, "x", false))]))
        #expect(throws: FilterExportError.disabledCondition) { try FilterFile.encode(saved) }
        #expect(FilterExportError.disabledCondition.description
            == "This filter has a disabled condition, which can't be exported yet.")
    }

    /// Export never writes a file Import would reject: it reads its own output back first.
    @Test func exportRefusesWhatImportWouldReject() {
        let badType = SavedFilter(
            id: UUID(), name: "T", expression: .all([cond(.type, .is, "DuckDuckGo")]))
        #expect(throws: FilterExportError.unreadable(.badTypeValue("DuckDuckGo"))) {
            try FilterFile.encode(badType)
        }
        // 32 levels read back fine; wrapped once more (as the bubble codec does for a
        // non-`all` root) it is one too deep.
        var deep = cond(.process, .is, "X")
        for _ in 0..<31 { deep = .not(deep) }
        let ok = SavedFilter(id: UUID(), name: "D", expression: deep)
        #expect((try? FilterFile.encode(ok)) != nil)
        let tooDeep = SavedFilter(id: UUID(), name: "D", expression: .all([deep]))
        #expect(throws: FilterExportError.unreadable(.tooDeep)) { try FilterFile.encode(tooDeep) }
        #expect(FilterExportError.unreadable(.tooDeep).description
            == "This filter can't be exported because BetterConsole couldn't read it back: "
            + "The filter is nested more than 32 levels deep.")
        #expect(FilterExportError.unreadable(.tooDeep).localizedDescription
            == FilterExportError.unreadable(.tooDeep).description)
    }

    /// Switching a bubble's field to Type keeps the value only if it is a Type.
    @Test func movingToTypeNormalisesTheValue() {
        let process = FilterCondition(field: .process, match: .contains, value: "DuckDuckGo")
        let moved = process.movedTo(.type)
        #expect(moved == FilterCondition(field: .type, match: .is, value: "default"))
        #expect(FilterCondition(field: .message, match: .is, value: "ERROR").movedTo(.type).value
            == "error")
        #expect(FilterCondition(field: .message, match: .is, value: "fault").movedTo(.type).value
            == "fault")
        // Other fields keep the value; a match the field does not allow becomes `is`.
        #expect(process.movedTo(.message)
            == FilterCondition(field: .message, match: .contains, value: "DuckDuckGo"))
        #expect(FilterCondition(field: .message, match: .regex, value: "4.").movedTo(.pid)
            == FilterCondition(field: .pid, match: .is, value: "4."))
        // Every moved-to-Type condition exports and imports back.
        for value in ["", "x", "Info", "debug", "123"] {
            let c = FilterCondition(field: .process, match: .startsWith, value: value).movedTo(.type)
            #expect(c.valueProblem == nil)
            let saved = SavedFilter(id: UUID(), name: "T", expression: .condition(c))
            #expect((try? FilterFile.decode(FilterFile.encode(saved))) == saved)
        }
    }

    @Test func unknownKeysOnExpressionNodesIgnored() throws {
        let f = try FilterFile.decode(file(expression: #"{"all":[\#(conditionJSON("process", "is", "X"))],"comment":"x"}"#))
        #expect(f.expression == .all([cond(.process, .is, "X")]))
    }

    @Test func fieldAndMatchCheckedBeforeValue() {
        #expect(throws: FilterImportError.unknownField("zone")) {
            try FilterFile.decode(file(expression: #"{"condition":{"field":"zone","match":"is"}}"#))
        }
    }

    @Test func nilExpressionWritesEmptyAllAndReadsBackNil() throws {
        let saved = SavedFilter(id: UUID(), name: "Empty", expression: nil)
        let data = try FilterFile.encode(saved)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expr = try #require(obj["expression"] as? [String: Any])
        #expect((expr["all"] as? [Any])?.isEmpty == true)
        #expect(try FilterFile.decode(data) == saved)
    }

    @Test func importRejects() {
        #expect(throws: FilterImportError.tooLarge) {
            try FilterFile.decode(Data(count: FilterFile.maxBytes + 1))
        }
        #expect(throws: FilterImportError.notJSON) { try FilterFile.decode(Data("nope".utf8)) }
        #expect(throws: FilterImportError.tooDeep) {
            try FilterFile.decode(file(expression: nested(nots: 33)))
        }
        #expect(throws: FilterImportError.wrongFormat) { try FilterFile.decode(file(format: "other")) }
        #expect(throws: FilterImportError.newerVersion(2)) { try FilterFile.decode(file(version: 2)) }
        #expect(throws: FilterImportError.missingName) { try FilterFile.decode(file(name: nil)) }
        #expect(throws: FilterImportError.missingName) { try FilterFile.decode(file(name: "   ")) }
        #expect(throws: FilterImportError.missingExpression) { try FilterFile.decode(file(expression: nil)) }
        #expect(throws: FilterImportError.unknownField("zone")) {
            try FilterFile.decode(file(expression: conditionJSON("zone", "is", "x")))
        }
        #expect(throws: FilterImportError.unknownMatch("near")) {
            try FilterFile.decode(file(expression: conditionJSON("process", "near", "x")))
        }
        #expect(throws: FilterImportError.disallowedMatch(field: "pid", match: "regex")) {
            try FilterFile.decode(file(expression: conditionJSON("pid", "regex", "1")))
        }
        #expect(throws: FilterImportError.disallowedMatch(field: "type", match: "contains")) {
            try FilterFile.decode(file(expression: conditionJSON("type", "contains", "debug")))
        }
        #expect(throws: FilterImportError.badTypeValue("warning")) {
            try FilterFile.decode(file(expression: conditionJSON("type", "is", "warning")))
        }
        #expect(throws: FilterImportError.disabledCondition) {
            try FilterFile.decode(
                file(expression: conditionJSON("process", "is", "x", extra: #","isEnabled":false"#)))
        }
    }

    @Test func rejectsProblemsNestedInGroups() {
        let bad = #"{"all":[{"any":[{"not":"# + conditionJSON("zone", "is", "x") + "}]}]}"
        #expect(throws: FilterImportError.unknownField("zone")) {
            try FilterFile.decode(file(expression: bad))
        }
    }

    @Test func depthLimitIsExactAndMalformedShapesAreRejected() throws {
        #expect(try FilterFile.decode(file(expression: nested(nots: 31))).expression != nil)
        #expect(throws: FilterImportError.tooDeep) {
            try FilterFile.decode(file(expression: nested(nots: 32)))
        }
        for bad in ["[]", "5", #"{"all":{}}"#, #"{}"#,
                    #"{"all":[],"any":[]}"#, #"{"condition":{"field":"process","match":"is"}}"#] {
            #expect(throws: FilterImportError.missingExpression) {
                try FilterFile.decode(file(expression: bad))
            }
        }
    }

    @Test func importAcceptsValueProblems() throws {
        let a = try FilterFile.decode(file(expression: conditionJSON("message", "regex", "(")))
        #expect(a.expression == cond(.message, .regex, "("))
        let b = try FilterFile.decode(file(expression: conditionJSON("pid", "is", "12a")))
        #expect(b.expression == cond(.pid, .is, "12a"))
        let c = try FilterFile.decode(
            file(expression: conditionJSON("type", "is", "FAULT", extra: #","isEnabled":true"#)))
        #expect(c.expression == cond(.type, .is, "FAULT"))
    }

    @Test func unknownExtraKeysIgnored() throws {
        let expr = conditionJSON("process", "is", "X", extra: #","color":"red""#)
        let f = try FilterFile.decode(file(expression: expr, extra: #""author":"me","tags":[1,2]"#))
        #expect(f.expression == cond(.process, .is, "X"))
    }

    @Test func idAndNameRead() throws {
        let id = UUID()
        let f = try FilterFile.decode(file(id: id.uuidString, name: "Mine"))
        #expect(f.id == id)
        #expect(f.name == "Mine")
        let missing = try FilterFile.decode(file(id: nil))
        let malformed = try FilterFile.decode(file(id: "not-a-uuid"))
        #expect(missing.id != malformed.id)
        #expect(missing.name == "DDG Errors")
    }

    /// A hand-edited export with format, version and id removed still imports; name and
    /// expression stay required, and a format or version that is present is still checked.
    @Test func formatVersionAndIDAreOptional() throws {
        let bare = try FilterFile.decode(file(format: nil, version: nil, id: nil))
        #expect(bare.name == "DDG Errors")
        #expect(bare.expression == cond(.process, .is, "X"))
        let other = try FilterFile.decode(file(format: nil, version: nil, id: nil))
        #expect(bare.id != other.id)

        #expect(throws: FilterImportError.missingName) {
            try FilterFile.decode(file(format: nil, version: nil, id: nil, name: nil))
        }
        #expect(throws: FilterImportError.missingExpression) {
            try FilterFile.decode(file(format: nil, version: nil, id: nil, expression: nil))
        }
        #expect(throws: FilterImportError.unknownField("zone")) {
            try FilterFile.decode(file(
                format: nil, version: nil, id: nil, expression: conditionJSON("zone", "is", "X")))
        }
        #expect(throws: FilterImportError.wrongFormat) { try FilterFile.decode(file(format: "other", version: nil)) }
        #expect(throws: FilterImportError.newerVersion(2)) { try FilterFile.decode(file(format: nil, version: 2)) }
        #expect(throws: FilterImportError.wrongFormat) {
            try FilterFile.decode(Data(#"{"version":"one","name":"N","expression":{"all":[]}}"#.utf8))
        }
    }
}
