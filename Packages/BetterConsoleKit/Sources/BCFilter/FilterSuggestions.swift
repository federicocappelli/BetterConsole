import Foundation

public struct FilterSuggestion: Hashable, Sendable {
    public var condition: FilterCondition
    public var title: String
}

public enum FilterSuggestions {
    public static let valuesPerField = 3

    /// Message contains first, then seen values that equal-match, then field-contains.
    public static func make(for text: String, seen: SeenValues) -> [FilterSuggestion] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }

        var result = [suggestion(.message, .contains, typed)]
        for field in [FilterField.process, .subsystem, .category, .library] {
            let matches = seen.values(for: field)
                .filter { $0.range(of: typed, options: .caseInsensitive) != nil }
                .sorted {
                    $0.count != $1.count ? $0.count < $1.count : $0 < $1
                }
            result += matches.prefix(valuesPerField).map { suggestion(field, .is, $0) }
        }
        for field in [FilterField.subsystem, .category, .process] {
            result.append(suggestion(field, .contains, typed))
        }
        return result
    }

    private static func suggestion(_ field: FilterField, _ match: MatchKind, _ value: String)
        -> FilterSuggestion
    {
        FilterSuggestion(
            condition: FilterCondition(field: field, match: match, value: value),
            title: "\(field.title) \(match.title) \"\(value)\"")
    }
}
