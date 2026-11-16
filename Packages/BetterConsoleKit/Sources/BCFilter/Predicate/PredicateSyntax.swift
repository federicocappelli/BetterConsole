import Foundation

/// Syntax colouring for the editor's text pane (ES §8.3), from the same lexer the parser
/// uses, so it works on text that doesn't parse.
public enum PredicateSyntax {
    public enum Role: Equatable, Sendable {
        /// A predicate key (`process`, `timeOfDay`, `extra`, `filter`), any case.
        case key
        /// `AND`, `OR`, `NOT`, `CONTAINS`, `MATCHES`, `BETWEEN`, `TRUEPREDICATE`…
        case keyword
        /// `==`, `>=`, `(`, `[`, `{`, `,`, `&&`…
        case `operator`
        /// A quoted string, quotes included.
        case string
        case number
        /// Any other word, such as a bare Type value (`error`).
        case value
        /// A whole `// …` line, from the `//` to the end of the line. The spans inside it are
        /// listed too.
        case disabledLine
    }

    public struct Span: Sendable {
        public var range: Range<String.Index>
        public var role: Role
    }

    /// In text order; a disabled line comes before the spans inside it. Text that can't be a
    /// token gets no span.
    public static func spans(in text: String) -> [Span] {
        var spans: [Span] = []
        var lineStart: (index: Int, start: String.Index)?
        for token in PredicateLexer.tokens(text) {
            let role: Role
            switch token.kind {
            case .word(let w):
                if spans.last?.role == .operator, text[spans.last!.range] == "[",
                   !w.isEmpty, w.lowercased().allSatisfy({ $0 == "c" || $0 == "d" }) {
                    role = .operator
                } else if keywords.contains(w.uppercased()) {
                    role = .keyword
                } else if keys.contains(w.lowercased()) {
                    role = .key
                } else {
                    role = .value
                }
            case .string: role = .string
            case .number: role = .number
            case .symbol: role = .operator
            case .disabledStart:
                lineStart = (spans.count, token.range.lowerBound)
                continue
            case .disabledEnd:
                if let (index, start) = lineStart {
                    spans.insert(Span(range: start..<token.range.lowerBound, role: .disabledLine), at: index)
                }
                lineStart = nil
                continue
            case .invalid, .end:
                continue
            }
            spans.append(Span(range: token.range, role: role))
        }
        return spans
    }

    /// The parser's keywords and reserved words (ES §6.1, §6.4).
    private static let keywords: Set<String> = [
        "AND", "OR", "NOT", "TRUEPREDICATE", "CONTAINS", "BEGINSWITH", "ENDSWITH", "MATCHES",
        "LIKE", "BETWEEN", "WHEN", "THEN", "IF", "ELSE",
    ]

    /// Lower-cased, as the parser reads keys.
    private static let keys: Set<String> = Set(
        (FilterField.allCases.map(\.predicateKey) + ["composedMessage", "filter"]).map { $0.lowercased() })
}
