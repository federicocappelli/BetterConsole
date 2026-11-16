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

    /// The main filter of a file; a text file without a name header is called "Fallback".
    private func decode(_ data: Data) throws(FilterImportError) -> SavedFilter {
        try FilterFile.decode(data, fallbackName: "Fallback").main
    }

    private func decodeText(_ text: String, fallbackName: String = "Fallback") throws(FilterImportError) -> DecodedFilterFile {
        try FilterFile.decode(Data(text.utf8), fallbackName: fallbackName)
    }

    /// The import error `body` throws, or nil.
    private func importError(_ body: () throws -> Void) -> FilterImportError? {
        do { try body(); return nil } catch { return error as? FilterImportError }
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
        #expect(try decode(data) == saved)
    }

    @Test func roundTripsEveryMatchKindAndGroup() throws {
        let expr: FilterExpression = .all([
            .any([cond(.process, .contains, "a"), cond(.subsystem, .is, "b")]),
            .not(.any([cond(.category, .startsWith, "c"), cond(.message, .regex, "d+")])),
            cond(.type, .is, "debug"),
        ])
        let saved = SavedFilter(id: UUID(), name: "All", expression: expr)
        #expect(try decode(FilterFile.encode(saved)) == saved)
    }

    /// ES §5.5: disabled conditions are written and read back (reverses FS ruling R4).
    @Test func importAcceptsDisabledConditions() throws {
        let saved = SavedFilter(
            id: UUID(), name: "D", expression: .all([.not(cond(.process, .is, "x", false))]))
        let data = try FilterFile.encode(saved)
        #expect(String(decoding: data, as: UTF8.self).contains(#""isEnabled" : false"#))
        #expect(try decode(data) == saved)
        let imported = try decode(
            file(expression: conditionJSON("process", "is", "x", extra: #","isEnabled":false"#)))
        #expect(imported.expression == cond(.process, .is, "x", false))
    }

    @Test func roundTripsNewFieldsMatchesAndLinks() throws {
        let linked = UUID()
        let expr: FilterExpression = .all([
            .condition(FilterCondition(field: .extra, match: .endsWith, value: "v", key: "k")),
            .condition(FilterCondition(
                field: .timeOfDay, match: .between, value: "22:00", upperValue: "02:00")),
            cond(.type, .greaterOrEqual, "error"), cond(.pid, .regex, "20.*"),
            cond(.thread, .lessThan, "0x10"), cond(.eventType, .is, "logEvent"),
            cond(.processPath, .startsWith, "/Applications"), cond(.senderPath, .contains, "UIKit"),
            .not(.link(linked)),
        ])
        let saved = SavedFilter(id: UUID(), name: "New", expression: expr)
        #expect(try decode(FilterFile.encode(saved)) == saved)
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
        #expect(FilterCondition(field: .message, match: .contains, value: "4.").movedTo(.pid)
            == FilterCondition(field: .pid, match: .is, value: "4."))
        // A regex stays a regex on Type, with its pattern kept.
        #expect(FilterCondition(field: .message, match: .regex, value: "de.*").movedTo(.type)
            == FilterCondition(field: .type, match: .regex, value: "de.*"))
        // Every moved-to-Type condition exports and imports back.
        for value in ["", "x", "Info", "debug", "123"] {
            let c = FilterCondition(field: .process, match: .startsWith, value: value).movedTo(.type)
            #expect(c.valueProblem == nil)
            let saved = SavedFilter(id: UUID(), name: "T", expression: .condition(c))
            #expect((try? decode(FilterFile.encode(saved))) == saved)
        }
    }

    @Test func unknownKeysOnExpressionNodesIgnored() throws {
        let f = try decode(file(expression: #"{"all":[\#(conditionJSON("process", "is", "X"))],"comment":"x"}"#))
        #expect(f.expression == .all([cond(.process, .is, "X")]))
    }

    @Test func fieldAndMatchCheckedBeforeValue() {
        #expect(throws: FilterImportError.unknownField("zone")) {
            try decode(file(expression: #"{"condition":{"field":"zone","match":"is"}}"#))
        }
    }

    @Test func nilExpressionWritesEmptyAllAndReadsBackNil() throws {
        let saved = SavedFilter(id: UUID(), name: "Empty", expression: nil)
        let data = try FilterFile.encode(saved)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expr = try #require(obj["expression"] as? [String: Any])
        #expect((expr["all"] as? [Any])?.isEmpty == true)
        #expect(try decode(data) == saved)
    }

    @Test func importRejects() {
        #expect(throws: FilterImportError.tooLarge) {
            try decode(Data(count: FilterFile.maxBytes + 1))
        }
        #expect(throws: FilterImportError.notJSON) { try decode(Data("{nope".utf8)) }
        #expect(throws: FilterImportError.tooDeep) {
            try decode(file(expression: nested(nots: 33)))
        }
        #expect(throws: FilterImportError.wrongFormat) { try decode(file(format: "other")) }
        #expect(throws: FilterImportError.newerVersion(2)) { try decode(file(version: 2)) }
        #expect(throws: FilterImportError.missingName) { try decode(file(name: nil)) }
        #expect(throws: FilterImportError.missingName) { try decode(file(name: "   ")) }
        #expect(throws: FilterImportError.missingExpression) { try decode(file(expression: nil)) }
        #expect(throws: FilterImportError.unknownField("zone")) {
            try decode(file(expression: conditionJSON("zone", "is", "x")))
        }
        #expect(throws: FilterImportError.unknownMatch("near")) {
            try decode(file(expression: conditionJSON("process", "near", "x")))
        }
        #expect(throws: FilterImportError.disallowedMatch(field: "pid", match: "contains")) {
            try decode(file(expression: conditionJSON("pid", "contains", "1")))
        }
        #expect(throws: FilterImportError.disallowedMatch(field: "message", match: "lessThan")) {
            try decode(file(expression: conditionJSON("message", "lessThan", "1")))
        }
        #expect(throws: FilterImportError.disallowedMatch(field: "timeOfDay", match: "is")) {
            try decode(file(expression: conditionJSON("timeOfDay", "is", "09:00")))
        }
        #expect(throws: FilterImportError.disallowedMatch(field: "process", match: "between")) {
            try decode(file(expression: conditionJSON("process", "between", "a")))
        }
        #expect(throws: FilterImportError.badTypeValue("warning")) {
            try decode(file(expression: conditionJSON("type", "greaterOrEqual", "warning")))
        }
        #expect(throws: FilterImportError.missingExpression) {
            try decode(file(expression: #"{"link":{"id":"not-a-uuid"}}"#))
        }
        #expect(throws: FilterImportError.missingExpression) {
            try decode(file(expression: #"{"link":"6F1C2B3A-0000-4000-8000-000000000001"}"#))
        }
        #expect(throws: FilterImportError.disallowedMatch(field: "type", match: "contains")) {
            try decode(file(expression: conditionJSON("type", "contains", "debug")))
        }
        #expect(throws: FilterImportError.badTypeValue("warning")) {
            try decode(file(expression: conditionJSON("type", "is", "warning")))
        }
    }

    @Test func rejectsProblemsNestedInGroups() {
        let bad = #"{"all":[{"any":[{"not":"# + conditionJSON("zone", "is", "x") + "}]}]}"
        #expect(throws: FilterImportError.unknownField("zone")) {
            try decode(file(expression: bad))
        }
    }

    @Test func depthLimitIsExactAndMalformedShapesAreRejected() throws {
        #expect(try decode(file(expression: nested(nots: 31))).expression != nil)
        #expect(throws: FilterImportError.tooDeep) {
            try decode(file(expression: nested(nots: 32)))
        }
        for bad in ["[]", "5", #"{"all":{}}"#, #"{}"#,
                    #"{"all":[],"any":[]}"#, #"{"condition":{"field":"process","match":"is"}}"#] {
            #expect(throws: FilterImportError.missingExpression) {
                try decode(file(expression: bad))
            }
        }
    }

    @Test func importAcceptsValueProblems() throws {
        let a = try decode(file(expression: conditionJSON("message", "regex", "(")))
        #expect(a.expression == cond(.message, .regex, "("))
        let b = try decode(file(expression: conditionJSON("pid", "is", "12a")))
        #expect(b.expression == cond(.pid, .is, "12a"))
        let c = try decode(
            file(expression: conditionJSON("type", "is", "FAULT", extra: #","isEnabled":true"#)))
        #expect(c.expression == cond(.type, .is, "FAULT"))
        // A time that doesn't parse and an empty Extra key are value problems, not rejections.
        let d = try decode(file(expression: conditionJSON(
            "timeOfDay", "between", "9am", extra: #","upperValue":"10:00""#)))
        #expect(d.expression == .condition(FilterCondition(
            field: .timeOfDay, match: .between, value: "9am", upperValue: "10:00")))
        let e = try decode(file(expression: conditionJSON("extra", "is", "v")))
        #expect(e.expression == .condition(FilterCondition(field: .extra, match: .is, value: "v")))
        let f = try decode(file(expression: conditionJSON("type", "regex", "warn.*")))
        #expect(f.expression == cond(.type, .regex, "warn.*"))
    }

    @Test func unknownExtraKeysIgnored() throws {
        let expr = conditionJSON("process", "is", "X", extra: #","color":"red""#)
        let f = try decode(file(expression: expr, extra: #""author":"me","tags":[1,2]"#))
        #expect(f.expression == cond(.process, .is, "X"))
    }

    @Test func idAndNameRead() throws {
        let id = UUID()
        let f = try decode(file(id: id.uuidString, name: "Mine"))
        #expect(f.id == id)
        #expect(f.name == "Mine")
        let missing = try decode(file(id: nil))
        let malformed = try decode(file(id: "not-a-uuid"))
        #expect(missing.id != malformed.id)
        #expect(missing.name == "DDG Errors")
    }

    /// A hand-edited export with format, version and id removed still imports; name and
    /// expression stay required, and a format or version that is present is still checked.
    @Test func formatVersionAndIDAreOptional() throws {
        let bare = try decode(file(format: nil, version: nil, id: nil))
        #expect(bare.name == "DDG Errors")
        #expect(bare.expression == cond(.process, .is, "X"))
        let other = try decode(file(format: nil, version: nil, id: nil))
        #expect(bare.id != other.id)

        #expect(throws: FilterImportError.missingName) {
            try decode(file(format: nil, version: nil, id: nil, name: nil))
        }
        #expect(throws: FilterImportError.missingExpression) {
            try decode(file(format: nil, version: nil, id: nil, expression: nil))
        }
        #expect(throws: FilterImportError.unknownField("zone")) {
            try decode(file(
                format: nil, version: nil, id: nil, expression: conditionJSON("zone", "is", "X")))
        }
        #expect(throws: FilterImportError.wrongFormat) { try decode(file(format: "other", version: nil)) }
        #expect(throws: FilterImportError.newerVersion(2)) { try decode(file(format: nil, version: 2)) }
        #expect(throws: FilterImportError.wrongFormat) {
            try decode(Data(#"{"version":"one","name":"N","expression":{"all":[]}}"#.utf8))
        }
    }

    // MARK: - Fields that don't use a key or end (Task 1 review)

    /// A `key` on a field other than Extra data and an `upperValue` on a field other than
    /// Time of day are dropped on import; `null` reads as a missing value.
    @Test func strayKeyAndUpperValueStripped() throws {
        let stray = try decode(file(expression: conditionJSON(
            "process", "is", "X", extra: #","key":"k","upperValue":"10:00""#)))
        #expect(stray.expression == cond(.process, .is, "X"))
        let extra = try decode(file(expression: conditionJSON(
            "extra", "is", "v", extra: #","key":"k","upperValue":"10:00""#)))
        #expect(extra.expression == .condition(FilterCondition(field: .extra, match: .is, value: "v", key: "k")))
        let time = try decode(file(expression: conditionJSON(
            "timeOfDay", "between", "09:00", extra: #","key":"k","upperValue":"10:00""#)))
        #expect(time.expression == .condition(FilterCondition(
            field: .timeOfDay, match: .between, value: "09:00", upperValue: "10:00")))
    }

    @Test func nullOptionalsReadAsMissing() throws {
        let extra = try decode(file(expression: conditionJSON("extra", "is", "v", extra: #","key":null"#)))
        #expect(extra.expression == .condition(FilterCondition(field: .extra, match: .is, value: "v")))
        #expect(extra.expression.flatMap { if case .condition(let c) = $0 { c.valueProblem } else { nil } }
            == "Enter a key")
        let time = try decode(file(expression: conditionJSON(
            "timeOfDay", "between", "09:00", extra: #","upperValue":null,"isEnabled":null"#)))
        #expect(time.expression == .condition(FilterCondition(field: .timeOfDay, match: .between, value: "09:00")))
        // A wrong type is still a rejection.
        #expect(throws: FilterImportError.missingExpression) {
            try decode(file(expression: conditionJSON("extra", "is", "v", extra: #","key":5"#)))
        }
    }

    // MARK: - Both formats (ES §7)

    /// `e` with every link id replaced by `f(id)`.
    private func mapLinks(_ e: FilterExpression?, _ f: (UUID) -> UUID) -> FilterExpression? {
        guard let e else { return nil }
        switch e {
        case .condition: return e
        case .link(let id): return .link(f(id))
        case .all(let xs): return .all(xs.map { mapLinks($0, f)! })
        case .any(let xs): return .any(xs.map { mapLinks($0, f)! })
        case .not(let x): return .not(mapLinks(x, f)!)
        }
    }

    /// The tree with its by-name links turned back into the ids of `bundle` filters of that
    /// name; other links are kept.
    private func relinked(
        _ e: FilterExpression?, _ d: DecodedFilterFile, bundle: [SavedFilter]
    ) -> FilterExpression? {
        mapLinks(e) { id in
            guard let name = d.linkNames[id]?.first else { return id }
            return bundle.first { $0.name == name }?.id ?? id
        }
    }

    private func bundleOfThree() -> (main: SavedFilter, linked: [SavedFilter]) {
        let heartbeat = SavedFilter(name: "Heartbeat", expression: cond(.category, .contains, "heartbeat"))
        let noise = SavedFilter(name: "Noise Exclusions", expression: .any([
            .link(heartbeat.id), cond(.subsystem, .startsWith, "com.apple.network"),
        ]))
        let main = SavedFilter(name: "DDG Errors", expression: .all([
            cond(.process, .is, "DuckDuckGo"), cond(.type, .greaterOrEqual, "error"),
            .not(.link(noise.id)), cond(.message, .contains, "skip", false),
        ]))
        return (main, [noise, heartbeat])
    }

    @Test func bothFormatsRoundTripWithBundles() throws {
        let (main, linked) = bundleOfThree()
        for format in FilterFileFormat.allCases {
            let data = try FilterFile.encode(main, linked: linked, format: format)
            let text = String(decoding: data, as: UTF8.self)
            let d = try FilterFile.decode(data, fallbackName: "Ignored")
            #expect(d.main.name == "DDG Errors", "\(format)")
            #expect(d.linked.map(\.name) == ["Noise Exclusions", "Heartbeat"], "\(format)")
            #expect(relinked(d.main.expression, d, bundle: linked) == main.expression, "\(format)")
            for (got, want) in zip(d.linked, linked) {
                #expect(relinked(got.expression, d, bundle: linked) == want.expression, "\(format)")
            }
            #expect(Set(d.linkNames.values.flatMap { $0 }) == ["Noise Exclusions", "Heartbeat"])
            // Links are written by name, never by the library's ids.
            for f in linked { #expect(!text.contains(f.id.uuidString), "\(format)") }
            switch format {
            case .predicate:
                #expect(text.hasPrefix("// BetterConsole filter\n// version: 1\n// name: DDG Errors\n"))
                #expect(text.contains("\n// filter: Noise Exclusions\n"))
                #expect(text.contains("\n// filter: Heartbeat\n"))
                #expect(text.contains(#"filter == "Noise Exclusions""#))
                #expect(text.contains(#"// AND eventMessage CONTAINS[c] "skip""#))
            case .json:
                let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let bundle = try #require(obj["linked"] as? [[String: Any]])
                #expect(bundle.compactMap { $0["name"] as? String } == ["Noise Exclusions", "Heartbeat"])
                #expect(text.contains(#""link" : {"#) && text.contains(#""name" : "Heartbeat""#))
            }
        }
        #expect(FilterFileFormat.predicate.fileExtension == "bcfilter")
        #expect(FilterFileFormat.json.fileExtension == "json")
        #expect(FilterFileFormat.predicate.title == "Predicate text")
        #expect(FilterFileFormat.json.title == "JSON")
    }

    /// `{` as the first non-space character means JSON, anything else predicate text.
    @Test func detectsFormatByContentInData() throws {
        let json = Data("\n  \t".utf8) + file()
        #expect(try decode(json).name == "DDG Errors")
        // A UTF-8 byte order mark before the JSON.
        let bom = Data([0xEF, 0xBB, 0xBF]) + file()
        #expect(try decode(bom).name == "DDG Errors")
        #expect(try decode(bom).expression == cond(.process, .is, "X"))
        let text = try decodeText("\n  process ==[c] \"X\"\n", fallbackName: "Plain")
        #expect(text.main == SavedFilter(id: text.main.id, name: "Plain", expression: cond(.process, .is, "X")))
        #expect(importError { _ = try decodeText("{ process == 1") } == .notJSON)
    }

    @Test func headerOptional() throws {
        let bare = try decodeText(#"process ==[c] "X" AND messageType >= error"#, fallbackName: "my file")
        #expect(bare.main.name == "my file")
        #expect(bare.main.expression == .all([cond(.process, .is, "X"), cond(.type, .greaterOrEqual, "error")]))
        #expect(bare.linked.isEmpty)
        // Name alone, without the first line or a version.
        let named = try decodeText("// name: Named\nprocess ==[c] \"X\"", fallbackName: "ignored")
        #expect(named.main.name == "Named")
        // An empty body is the empty filter.
        let empty = try decodeText("// name: Empty\n\n", fallbackName: "ignored")
        #expect(empty.main.expression == nil)
        #expect(importError { _ = try decodeText("process ==[c] \"X\"", fallbackName: "  ") } == .missingName)
        #expect(importError { _ = try decodeText("// version: 2\n// name: N\nTRUEPREDICATE") } == .newerVersion(2))
        // A first line that is a disabled condition is a body line, not a header.
        let disabled = try decodeText("// process ==[c] \"X\"", fallbackName: "D")
        #expect(disabled.main.expression == cond(.process, .is, "X", false))
    }

    @Test func predicateErrorsGiveLineNumbers() {
        func line(_ text: String) -> Int? {
            if case .predicate(let line, _) = importError({ _ = try decodeText(text) }) { line } else { nil }
        }
        #expect(line("// name: N\nprocess ==[c] \"a\"\nAND bogus == \"b\"") == 3)
        #expect(line("process ==[c] \"a\"\nAND (") == 2)
        #expect(line("// name: N\nprocess ==[c] \"a\"\n\n// filter: L\ncategory ==[c] \"x\"\nOR OR") == 6)
        #expect(line("// BetterConsole filter\n// version: one\n// name: N\nTRUEPREDICATE") == 2)
        #expect(line("// name: \"open\nTRUEPREDICATE") == 1)
        #expect(line("// name: N\nTRUEPREDICATE\n// filter:\nTRUEPREDICATE") == 3)
        #expect(line("// name: N\n// name: M\nTRUEPREDICATE") == 2)
        // A Type value that isn't a Type is rejected as in JSON, on its line.
        #expect(line("// name: N\nprocess ==[c] \"a\"\nAND messageType == \"warning\"") == 3)
        // …the line of the comparison itself, not an earlier regex with the same text.
        #expect(line("// name: N\nmessageType MATCHES \"warning\"\nAND messageType == \"warning\"") == 3)
        #expect(line("// name: N\nprocess ==[c] \"messageType\" OR\nprocess ==[c] \"warning\"\nOR messageType == warning") == 4)
        // Old-Mac (CR only) and Windows (CRLF) line endings count lines the same way.
        #expect(line("// name: N\rprocess ==[c] \"a\"\rAND bogus == \"b\"") == 3)
        #expect(line("// name: N\r\nprocess ==[c] \"a\"\r\nAND bogus == \"b\"") == 3)
        // Two linked sections with the same name.
        let twice = "// name: N\nfilter == \"X\"\n// filter: X\nTRUEPREDICATE\n// filter: X\nTRUEPREDICATE"
        #expect(line(twice) == 5)
        if case .predicate(_, let message) = importError({ _ = try decodeText(twice) }) {
            #expect(message == "A linked filter named ‘X’ is already in the file")
        }
        let error = importError { _ = try decodeText("// name: N\nprocess ==[c] \"a\"\nAND bogus == \"b\"") }
        #expect(error?.description.hasPrefix("Line 3: ") == true)
    }

    @Test func unicodeNameInHeader() throws {
        let beetle = SavedFilter(name: "Käfer 🐛", expression: cond(.message, .contains, "🐛"))
        let main = SavedFilter(name: "Bugs 🐞", expression: .any([.link(beetle.id), cond(.process, .is, "ü")]))
        let data = try FilterFile.encode(main, linked: [beetle], format: .predicate)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("// name: Bugs 🐞\n"))
        #expect(text.contains("// filter: Käfer 🐛\n"))
        let d = try FilterFile.decode(data, fallbackName: "x")
        #expect(d.main.name == "Bugs 🐞")
        #expect(d.linked.map(\.name) == ["Käfer 🐛"])
        #expect(relinked(d.main.expression, d, bundle: [beetle]) == main.expression)
        // Names a header line can't hold as they are are written quoted.
        for name in ["Two\nLines", "  padded  ", #""quoted""#, #"Quote "q""#, #"Back\slash"#, "a) OR (b"] {
            let f = SavedFilter(name: name, expression: nil)
            let l = SavedFilter(name: name + " L", expression: nil)
            let m = SavedFilter(name: name, expression: .link(l.id))
            for format in FilterFileFormat.allCases {
                let round = try FilterFile.decode(
                    FilterFile.encode(m, linked: [l], format: format), fallbackName: "x")
                #expect(round.main.name == name, "\(format) \(name)")
                #expect(round.linked.map(\.name) == [l.name], "\(format) \(name)")
                #expect(relinked(round.main.expression, round, bundle: [l]) == m.expression)
                #expect(try FilterFile.decode(FilterFile.encode(f, linked: [], format: format),
                                              fallbackName: "x").main.name == name)
            }
        }
    }

    @Test func loopingBundleRejected() {
        let loop = """
            // name: Main
            filter == "A"

            // filter: A
            filter == "B"

            // filter: B
            process ==[c] "x" OR filter == "a"
            """
        #expect(importError { _ = try decodeText(loop) } == .linkLoop)
        #expect(importError { _ = try decodeText("// name: M\nTRUEPREDICATE\n// filter: S\nfilter == \"S\"") } == .linkLoop)
        let json = #"""
            {"name":"Main","expression":{"link":{"name":"A"}},"linked":[
              {"name":"A","expression":{"link":{"name":"B"}}},
              {"name":"B","expression":{"not":{"link":{"name":"A"}}}}]}
            """#
        #expect(importError { _ = try FilterFile.decode(Data(json.utf8), fallbackName: "x") } == .linkLoop)
        // Main linking a bundled filter that links a filter named like main is not a loop:
        // main is not part of the bundle.
        let notLoop = "// name: Main\nfilter == \"A\"\n// filter: A\nfilter == \"Main\""
        #expect(importError { _ = try decodeText(notLoop) } == nil)
        #expect(FilterImportError.linkLoop.description
            == "The linked filters in the file include each other in a loop.")
    }

    /// Every tree the Task 4 generator builds, exported in each format with its linked filters,
    /// imports back: JSON as written (minus stray keys), text as the parser reads it. A Type
    /// value that isn't a Type is refused at export, as in Phase 3.
    @Test func exportOfAnythingBuildableReimports() throws {
        for seed in UInt64(0)..<150 {
            var g = RandomFilterTrees(seed: seed)
            // The linked filters a library could hold (a saved filter always has a name).
            let bundle = g.names
                .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.value < $1.value }
                .map { SavedFilter(id: $0.key, name: $0.value, expression: Self.withTypesFixed(.condition(g.condition()))) }
            for _ in 0..<4 {
                let raw = g.tree()
                for tree in [raw, Self.withTypesFixed(raw)] {
                    let main = SavedFilter(name: "Main \(seed)", expression: tree)
                    for format in FilterFileFormat.allCases {
                        let context = "seed \(seed) \(format) \(String(describing: tree))"
                        if Self.hasBadType(tree) {
                            #expect(throws: FilterExportError.self, "\(context)") {
                                try FilterFile.encode(main, linked: bundle, format: format)
                            }
                            continue
                        }
                        let data = try FilterFile.encode(main, linked: bundle, format: format)
                        let d = try FilterFile.decode(data, fallbackName: "x")
                        let expected = format == .json
                            ? Self.stripped(tree).flatMap { $0 == .all([]) ? nil : $0 }
                            : FilterNormaliser.normalised(tree)
                        #expect(d.main.name == main.name, "\(context)")
                        #expect(relinked(d.main.expression, d, bundle: bundle) == expected, "\(context)")
                        #expect(d.linked.map(\.name) == bundle.map(\.name), "\(context)")
                    }
                }
            }
        }
    }

    /// Whether a Type condition outside a regex has a value that isn't a Type.
    private static func hasBadType(_ e: FilterExpression?) -> Bool {
        switch e {
        case nil: false
        case .condition(let c): c.field == .type && c.match != .regex && FilterCondition.parseLevel(c.value) == nil
        case .link: false
        case .all(let xs), .any(let xs): xs.contains { hasBadType($0) }
        case .not(let x): hasBadType(x)
        }
    }

    private static func withTypesFixed(_ e: FilterExpression?) -> FilterExpression? {
        mapConditions(e) { c in
            var c = c
            if c.field == .type, c.match != .regex, FilterCondition.parseLevel(c.value) == nil { c.value = "error" }
            return c
        }
    }

    private static func mapConditions(
        _ e: FilterExpression?, _ f: (FilterCondition) -> FilterCondition
    ) -> FilterExpression? {
        guard let e else { return nil }
        switch e {
        case .condition(let c): return .condition(f(c))
        case .link: return e
        case .all(let xs): return .all(xs.map { mapConditions($0, f)! })
        case .any(let xs): return .any(xs.map { mapConditions($0, f)! })
        case .not(let x): return .not(mapConditions(x, f)!)
        }
    }

    /// Without a key outside Extra data or an end outside Time of day.
    private static func stripped(_ e: FilterExpression?) -> FilterExpression? {
        mapConditions(e) { c in
            var c = c
            if c.field != .extra { c.key = nil }
            if c.field != .timeOfDay { c.upperValue = nil }
            return c
        }
    }
}
