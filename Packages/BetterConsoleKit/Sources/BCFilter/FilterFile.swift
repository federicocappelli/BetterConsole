import Foundation

/// A named filter in the app's library. A nil expression is the empty filter.
public struct SavedFilter: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var expression: FilterExpression?

    public init(id: UUID = UUID(), name: String, expression: FilterExpression?) {
        self.id = id
        self.name = name
        self.expression = expression
    }
}

public enum FilterImportError: Error, Equatable, CustomStringConvertible {
    case tooLarge, notJSON, tooDeep, wrongFormat
    case newerVersion(Int)
    case missingName, missingExpression
    case unknownField(String)
    case unknownMatch(String)
    case disallowedMatch(field: String, match: String)
    case badTypeValue(String)
    /// A problem in a predicate text file, on its line (1-based).
    case predicate(line: Int, message: String)
    /// The file's linked filters link each other in a loop.
    case linkLoop

    public var description: String {
        switch self {
        case .tooLarge: "The file is larger than 1 MB."
        case .notJSON: "The file is not valid JSON."
        case .tooDeep: "The filter is nested more than \(FilterFile.maxDepth) levels deep."
        case .wrongFormat: "The file is not a BetterConsole filter."
        case .newerVersion(let v):
            "The file was made by a newer version of BetterConsole (format version \(v))."
        case .missingName: "The filter has no name."
        case .missingExpression: "The filter has no valid expression."
        case .unknownField(let f): "Unknown field “\(f)”."
        case .unknownMatch(let m): "Unknown match “\(m)”."
        case .disallowedMatch(let field, let match):
            "“\(match)” can't be used with \(FilterField(rawValue: field)?.title ?? field)."
        case .badTypeValue(let v):
            "“\(v)” is not a Type. Use default, info, debug, error or fault."
        case .predicate(let line, let message): "Line \(line): \(message)"
        case .linkLoop: "The linked filters in the file include each other in a loop."
        }
    }
}

public enum FilterExportError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The written file would be rejected by Import, for the reason given.
    case unreadable(FilterImportError)

    public var description: String {
        switch self {
        case .unreadable(let reason):
            "This filter can't be exported because BetterConsole couldn't read it back: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

/// The two export formats (ES §7.1).
public enum FilterFileFormat: String, CaseIterable, Sendable {
    case predicate, json

    public var fileExtension: String {
        switch self {
        case .predicate: "bcfilter"
        case .json: "json"
        }
    }

    public var title: String {
        switch self {
        case .predicate: "Predicate text"
        case .json: "JSON"
        }
    }
}

/// A filter file as read, before the library resolves its links (ES §7.2).
public struct DecodedFilterFile: Sendable {
    public var main: SavedFilter
    /// The linked filters bundled in the file, in file order, with names as written.
    public var linked: [SavedFilter]
    /// Links written by name are `.link(placeholder)` in the trees above. Each placeholder id
    /// maps to the name written (one placeholder per exact spelling, so the array holds that
    /// one name).
    public var linkNames: [UUID: [String]]

    public init(main: SavedFilter, linked: [SavedFilter], linkNames: [UUID: [String]]) {
        self.main = main
        self.linked = linked
        self.linkNames = linkNames
    }

    /// The name a placeholder link was written with, or nil for a link by id.
    public func linkName(_ id: UUID) -> String? { linkNames[id]?.first }

    /// The index in `linked` a link to `name` means: the exact name first, else the first
    /// with that name in any case (ES §6.6).
    public func bundleIndex(of name: String) -> Int? {
        linked.firstIndex { $0.name == name }
            ?? linked.firstIndex { $0.name.lowercased() == name.lowercased() }
    }
}

public enum FilterFile {
    public static let format = "betterconsole.filter"
    public static let version = 1
    public static let maxBytes = 1_048_576
    public static let maxDepth = 32

    /// `main` and its linked filters as a file. Links to filters in `linked` are written by
    /// name; any other link is written as missing. The output is read back first, so a file
    /// Import would reject is never written.
    public static func encode(
        _ main: SavedFilter, linked: [SavedFilter] = [], format: FilterFileFormat = .json
    ) throws -> Data {
        let names = Dictionary(linked.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let data = switch format {
        case .json: try encodeJSON(main, linked: linked, names: names)
        case .predicate: Data(encodeText(main, linked: linked, names: names).utf8)
        }
        do { _ = try decode(data, fallbackName: main.name) } catch { throw FilterExportError.unreadable(error) }
        return data
    }

    /// Reads a file in either format: a first non-space character `{` means JSON, anything
    /// else predicate text. A text file without a `// name:` header is called `fallbackName`.
    public static func decode(
        _ data: Data, fallbackName: String
    ) throws(FilterImportError) -> DecodedFilterFile {
        guard data.count <= maxBytes else { throw .tooLarge }
        let file: DecodedFilterFile
        if firstNonSpaceByte(data) == UInt8(ascii: "{") {
            file = try decodeJSON(data)
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw .wrongFormat }
            file = try decodeText(text, fallbackName: fallbackName)
        }
        try checkLoops(file)
        return file
    }

    private static func firstNonSpaceByte(_ data: Data) -> UInt8? {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return bytes.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }
    }

    // MARK: - Links by name

    /// One placeholder id per exact link name in a file.
    private struct LinkTable {
        var ids: [String: UUID] = [:]

        mutating func placeholder(for name: String) -> UUID {
            if let id = ids[name] { return id }
            let id = UUID()
            ids[name] = id
            return id
        }

        var linkNames: [UUID: [String]] {
            Dictionary(uniqueKeysWithValues: ids.map { ($0.value, [$0.key]) })
        }
    }

    /// A bundle whose filters link each other in a loop is rejected (ES §7.2). Only links to
    /// bundled filters count: the main filter is not in the bundle, and a link that resolves
    /// to an existing filter can't reach the new ones.
    private static func checkLoops(_ file: DecodedFilterFile) throws(FilterImportError) {
        let edges = file.linked.map { member in
            FilterLinks.links(in: member.expression).compactMap { file.linkName($0) }
                .compactMap { file.bundleIndex(of: $0) }
        }
        var state = [UInt8](repeating: 0, count: edges.count) // 0 new, 1 on path, 2 done
        func visit(_ i: Int) -> Bool {
            if state[i] == 1 { return true }
            if state[i] == 2 { return false }
            state[i] = 1
            for j in edges[i] where visit(j) { return true }
            state[i] = 2
            return false
        }
        for i in edges.indices where visit(i) { throw .linkLoop }
    }

    // MARK: - JSON

    private static func encodeJSON(
        _ main: SavedFilter, linked: [SavedFilter], names: [UUID: String]
    ) throws -> Data {
        func object(_ e: FilterExpression?) throws -> Any {
            let json = try JSONEncoder().encode(e ?? .all([]))
            return linksByName(try JSONSerialization.jsonObject(with: json), names)
        }
        var root: [String: Any] = [
            "format": format, "version": version, "id": main.id.uuidString, "name": main.name,
            "expression": try object(main.expression),
        ]
        if !linked.isEmpty {
            root["linked"] = try linked.map { ["name": $0.name, "expression": try object($0.expression)] }
        }
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// The encoded tree with `{"link":{"id":…}}` written `{"link":{"name":…}}` where the id
    /// has a name.
    private static func linksByName(_ node: Any, _ names: [UUID: String]) -> Any {
        guard var dict = node as? [String: Any] else { return node }
        for key in ["all", "any"] {
            if let children = dict[key] as? [Any] { dict[key] = children.map { linksByName($0, names) } }
        }
        if let child = dict["not"] { dict["not"] = linksByName(child, names) }
        if let link = dict["link"] as? [String: Any],
           let id = (link["id"] as? String).flatMap(UUID.init(uuidString:)), let name = names[id] {
            dict["link"] = ["name": name]
        }
        return dict
    }

    private static func decodeJSON(_ data: Data) throws(FilterImportError) -> DecodedFilterFile {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw .notJSON }
        guard let object = root as? [String: Any] else { throw .wrongFormat }
        // `format`, `version` and `id` may be left out of a hand-edited file: a missing format
        // or version reads as this one, a missing id gets a new one. When present they are
        // still checked. `name` and `expression` are always required.
        if let f = object["format"], f as? String != format { throw .wrongFormat }
        if let rawVersion = object["version"] {
            guard let v = rawVersion as? Int, v >= 1 else { throw .wrongFormat }
            if v > version { throw .newerVersion(v) }
        }
        var table = LinkTable()
        var main = try jsonFilter(object, table: &table)
        main.id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        var linked: [SavedFilter] = []
        if let raw = object["linked"], !(raw is NSNull) {
            guard let members = raw as? [Any] else { throw .wrongFormat }
            for member in members {
                guard let dict = member as? [String: Any] else { throw .wrongFormat }
                linked.append(try jsonFilter(dict, table: &table))
            }
        }
        return DecodedFilterFile(main: main, linked: linked, linkNames: table.linkNames)
    }

    /// A `{name, expression}` object, with a new id.
    private static func jsonFilter(
        _ object: [String: Any], table: inout LinkTable
    ) throws(FilterImportError) -> SavedFilter {
        guard let name = object["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw .missingName }
        guard let expressionObject = object["expression"] else { throw .missingExpression }
        guard nodeDepth(expressionObject) <= maxDepth else { throw .tooDeep }
        let cleaned = try sanitised(expressionObject, table: &table)
        let expression: FilterExpression
        do {
            let json = try JSONSerialization.data(withJSONObject: cleaned)
            expression = try JSONDecoder().decode(FilterExpression.self, from: json)
        } catch { throw .missingExpression }
        return SavedFilter(name: name, expression: expression == .all([]) ? nil : expression)
    }

    /// Depth of the expression tree, root = 1. Stops descending once past the limit.
    private static func nodeDepth(_ node: Any, _ level: Int = 1) -> Int {
        guard level <= maxDepth, let dict = node as? [String: Any] else { return level }
        var deepest = level
        for key in ["all", "any"] {
            for child in dict[key] as? [Any] ?? [] {
                deepest = max(deepest, nodeDepth(child, level + 1))
            }
        }
        if let child = dict["not"] { deepest = max(deepest, nodeDepth(child, level + 1)) }
        return deepest
    }

    /// The node checked and cleaned for decoding: unknown keys dropped, links by name turned
    /// into placeholder ids, and conditions as `sanitisedCondition` leaves them.
    private static func sanitised(
        _ node: Any, table: inout LinkTable
    ) throws(FilterImportError) -> [String: Any] {
        guard let dict = node as? [String: Any] else { throw .missingExpression }
        let known = ["condition", "all", "any", "not", "link"].filter { dict[$0] != nil }
        guard known.count == 1, let key = known.first, let value = dict[key]
        else { throw .missingExpression }
        switch key {
        case "all", "any":
            guard let children = value as? [Any] else { throw .missingExpression }
            var cleaned: [Any] = []
            for child in children { cleaned.append(try sanitised(child, table: &table)) }
            return [key: cleaned]
        case "not":
            return [key: try sanitised(value, table: &table)]
        case "condition":
            guard let c = value as? [String: Any] else { throw .missingExpression }
            return [key: try sanitisedCondition(c)]
        default: // link: by id (a missing link, or the app's own form) or by name (ES §7.1)
            guard let link = value as? [String: Any] else { throw .missingExpression }
            switch (link["id"], link["name"]) {
            case (let id as String, nil) where UUID(uuidString: id) != nil:
                return [key: ["id": id]]
            case (nil, let name as String):
                return [key: ["id": table.placeholder(for: name).uuidString]]
            default:
                throw .missingExpression
            }
        }
    }

    /// The condition checked, with `null` read as missing and a key or end the field doesn't
    /// use dropped (only Extra data has a key, only Time of day an end).
    private static func sanitisedCondition(
        _ raw: [String: Any]
    ) throws(FilterImportError) -> [String: Any] {
        var c = raw.filter { !($0.value is NSNull) }
        guard let fieldName = c["field"] as? String, let matchName = c["match"] as? String
        else { throw .missingExpression }
        guard let field = FilterField(rawValue: fieldName) else { throw .unknownField(fieldName) }
        guard let match = MatchKind(rawValue: matchName) else { throw .unknownMatch(matchName) }
        guard field.allowedMatches.contains(match) else {
            throw .disallowedMatch(field: fieldName, match: matchName)
        }
        guard let value = c["value"] as? String else { throw .missingExpression }
        for optional in ["key", "upperValue"] where c[optional] != nil {
            guard c[optional] is String else { throw .missingExpression }
        }
        if let enabled = c["isEnabled"] {
            guard let n = enabled as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID()
            else { throw .missingExpression }
        }
        if field != .extra { c["key"] = nil }
        if field != .timeOfDay { c["upperValue"] = nil }
        if isBadType(field: field, match: match, value: value) { throw .badTypeValue(value) }
        return c
    }

    /// A Type value is checked unless it is a regex pattern; times, Extra keys, numbers and
    /// patterns are value problems shown in red, not rejections (ES §5.5).
    private static func isBadType(field: FilterField, match: MatchKind, value: String) -> Bool {
        field == .type && match != .regex && FilterCondition.parseLevel(value) == nil
    }

    // MARK: - Predicate text (ES §7.1)

    private static let firstLine = "// BetterConsole filter"

    private static func encodeText(
        _ main: SavedFilter, linked: [SavedFilter], names: [UUID: String]
    ) -> String {
        func body(_ e: FilterExpression?) -> String {
            PredicateWriter.write(e, nameForLink: { names[$0] }).text
        }
        var out = "\(firstLine)\n// version: \(version)\n// name: \(headerValue(main.name))\n"
            + body(main.expression) + "\n"
        for filter in linked {
            out += "\n// filter: \(headerValue(filter.name))\n" + body(filter.expression) + "\n"
        }
        return out
    }

    /// A name as written after `name:` or `filter:`: as it is, or quoted with the predicate
    /// escapes when a header line can't hold it as it is (empty, starting with a quote,
    /// spaces at either end, line breaks or other control characters).
    private static func headerValue(_ name: String) -> String {
        let plain = !name.isEmpty && !name.hasPrefix("\"")
            && name == name.trimmingCharacters(in: .whitespaces)
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0)
                || CharacterSet.newlines.contains($0) }
        guard !plain else { return name }
        var r = "\""
        for ch in name.unicodeScalars {
            switch ch {
            case "\\": r += "\\\\"
            case "\"": r += "\\\""
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default: r.unicodeScalars.append(ch)
            }
        }
        return r + "\""
    }

    /// A header line's key (`name`, `version` or `filter`) and the text after its colon.
    private static func header(_ line: Substring) -> (key: String, value: Substring)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("//") else { return nil }
        let rest = trimmed.dropFirst(2).drop { $0 == " " || $0 == "\t" }
        for key in ["name", "version", "filter"] where rest.hasPrefix(key + ":") {
            return (key, rest.dropFirst(key.count + 1))
        }
        return nil
    }

    /// A header's name: the trimmed text, or the string it quotes.
    private static func headerName(_ raw: Substring, line: Int) throws(FilterImportError) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("\"") else { return value }
        let tokens = PredicateLexer.tokens(value)
        guard tokens.count == 2, case .string(let s) = tokens[0].kind, tokens[1].kind == .end else {
            throw .predicate(line: line, message: "Expected a name in quotes")
        }
        return s
    }

    /// Header lines (`// BetterConsole filter`, `// version:`, `// name:`) and blank lines,
    /// then the main filter's body up to the first `// filter:` line, then each linked filter
    /// as `// filter: <name>` and its body. A `//` line in a body is a disabled condition.
    private static func decodeText(
        _ raw: String, fallbackName: String
    ) throws(FilterImportError) -> DecodedFilterFile {
        // CRLF (Windows) and lone CR (old Mac) line endings both count as one line break.
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        var name: String?
        var versionSeen = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == firstLine { i += 1; continue }
            guard let h = header(line), h.key != "filter" else { break }
            if h.key == "name" {
                guard name == nil else { throw .predicate(line: i + 1, message: "The name is given twice") }
                let n = try headerName(h.value, line: i + 1)
                guard !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw .predicate(line: i + 1, message: "Expected a name after // name:")
                }
                name = n
            } else {
                guard !versionSeen else {
                    throw .predicate(line: i + 1, message: "The version is given twice")
                }
                versionSeen = true
                guard let v = Int(h.value.trimmingCharacters(in: .whitespaces)), v >= 1 else {
                    throw .predicate(line: i + 1, message: "The version must be a whole number")
                }
                if v > version { throw .newerVersion(v) }
            }
            i += 1
        }

        func bodyEnd(from start: Int) -> Int {
            var j = start
            while j < lines.count, header(lines[j])?.key != "filter" { j += 1 }
            return j
        }
        var table = LinkTable()
        let mainEnd = bodyEnd(from: i)
        let mainExpression = try parseBody(lines[i..<mainEnd], firstLine: i + 1, table: &table)
        var linked: [SavedFilter] = []
        var j = mainEnd
        while j < lines.count, let h = header(lines[j]) {
            let linkedName = try headerName(h.value, line: j + 1)
            guard !linkedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw .predicate(line: j + 1, message: "Expected a name after // filter:")
            }
            guard !linked.contains(where: { $0.name == linkedName }) else {
                throw .predicate(
                    line: j + 1, message: "A linked filter named ‘\(linkedName)’ is already in the file")
            }
            let end = bodyEnd(from: j + 1)
            let e = try parseBody(lines[(j + 1)..<end], firstLine: j + 2, table: &table)
            linked.append(SavedFilter(name: linkedName, expression: e))
            j = end
        }

        let mainName = name ?? fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mainName.isEmpty else { throw .missingName }
        return DecodedFilterFile(
            main: SavedFilter(name: mainName, expression: mainExpression), linked: linked,
            linkNames: table.linkNames)
    }

    /// One section's body read as a filter, with the checks JSON import makes (ES §7.2).
    /// Errors give the line in the file; `firstLine` is the body's first line (1-based).
    private static func parseBody(
        _ lines: ArraySlice<Substring>, firstLine: Int, table: inout LinkTable
    ) throws(FilterImportError) -> FilterExpression? {
        let body = lines.joined(separator: "\n")
        func line(at index: String.Index) -> Int {
            firstLine + body.utf8[..<index].lazy.filter { $0 == UInt8(ascii: "\n") }.count
        }
        // A Type value that isn't a Type is rejected as in JSON, at the value itself.
        let parsed = PredicateParser.parse(
            body, linkForName: { .found(table.placeholder(for: $0)) },
            conditionProblem: { c in
                isBadType(field: c.field, match: c.match, value: c.value)
                    ? FilterImportError.badTypeValue(c.value).description : nil
            })
        let expression: FilterExpression?
        switch parsed {
        case .success(let e): expression = e
        case .failure(let error):
            throw .predicate(line: line(at: error.range.lowerBound), message: error.message)
        }
        guard let expression else { return nil }
        guard depth(expression) <= maxDepth else { throw .tooDeep }
        return expression
    }

    /// The tree's depth, root = 1, as files count it. Every tree the app keeps stays within
    /// `maxDepth` (the parser, the editor and the workspace refuse deeper ones), so whatever
    /// the app holds can be persisted, exported and read back.
    public static func depth(_ e: FilterExpression) -> Int {
        switch e {
        case .condition, .link: 1
        case .all(let xs), .any(let xs): 1 + (xs.map(depth).max() ?? 0)
        case .not(let x): 1 + depth(x)
        }
    }
}
