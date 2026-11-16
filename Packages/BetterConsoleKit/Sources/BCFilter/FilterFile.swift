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
    case disabledCondition

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
        case .disabledCondition: "Disabled conditions are not supported."
        }
    }
}

public enum FilterExportError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case disabledCondition
    /// The written file would be rejected by Import, for the reason given.
    case unreadable(FilterImportError)

    public var description: String {
        switch self {
        case .disabledCondition:
            "This filter has a disabled condition, which can't be exported yet."
        case .unreadable(let reason):
            "This filter can't be exported because BetterConsole couldn't read it back: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

public enum FilterFile {
    public static let format = "betterconsole.filter"
    public static let version = 1
    public static let maxBytes = 1_048_576
    public static let maxDepth = 32

    private struct Envelope: Encodable {
        var format: String
        var version: Int
        var id: UUID
        var name: String
        var expression: FilterExpression
    }

    public static func encode(_ filter: SavedFilter) throws -> Data {
        if let expression = filter.expression, hasDisabledCondition(expression) {
            throw FilterExportError.disabledCondition
        }
        let envelope = Envelope(
            format: format, version: version, id: filter.id, name: filter.name,
            expression: filter.expression ?? .all([]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        // Never write a file Import would reject (a bad Type value, one level too deep…).
        do { _ = try decode(data) } catch { throw FilterExportError.unreadable(error) }
        return data
    }

    public static func decode(_ data: Data) throws(FilterImportError) -> SavedFilter {
        guard data.count <= maxBytes else { throw .tooLarge }
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
        guard let name = object["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw .missingName }
        guard let expressionObject = object["expression"] else { throw .missingExpression }
        guard nodeDepth(expressionObject) <= maxDepth else { throw .tooDeep }
        try validate(expressionObject)
        let expression: FilterExpression
        do {
            let json = try JSONSerialization.data(withJSONObject: expressionObject)
            expression = try JSONDecoder().decode(FilterExpression.self, from: json)
        } catch { throw .missingExpression }
        let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        return SavedFilter(
            id: id, name: name, expression: expression == .all([]) ? nil : expression)
    }

    private static func hasDisabledCondition(_ e: FilterExpression) -> Bool {
        switch e {
        case .condition(let c): !c.isEnabled
        case .all(let xs), .any(let xs): xs.contains(where: hasDisabledCondition)
        case .not(let x): hasDisabledCondition(x)
        }
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

    private static func validate(_ node: Any) throws(FilterImportError) {
        guard let dict = node as? [String: Any] else { throw .missingExpression }
        let known = ["condition", "all", "any", "not"].filter { dict[$0] != nil }
        guard known.count == 1, let key = known.first, let value = dict[key]
        else { throw .missingExpression }
        switch key {
        case "all", "any":
            guard let children = value as? [Any] else { throw .missingExpression }
            for child in children { try validate(child) }
        case "not":
            try validate(value)
        case "condition":
            guard let c = value as? [String: Any] else { throw .missingExpression }
            try validateCondition(c)
        default:
            throw .missingExpression
        }
    }

    private static func validateCondition(_ c: [String: Any]) throws(FilterImportError) {
        guard let fieldName = c["field"] as? String, let matchName = c["match"] as? String
        else { throw .missingExpression }
        guard let field = FilterField(rawValue: fieldName) else { throw .unknownField(fieldName) }
        guard let match = MatchKind(rawValue: matchName) else { throw .unknownMatch(matchName) }
        guard field.allowedMatches.contains(match) else {
            throw .disallowedMatch(field: fieldName, match: matchName)
        }
        guard c["value"] is String else { throw .missingExpression }
        if let enabled = c["isEnabled"] {
            guard let n = enabled as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue
            else { throw .disabledCondition }
        }
        if field == .type, let value = c["value"] as? String, FilterCondition.parseLevel(value) == nil {
            throw .badTypeValue(value)
        }
    }
}
