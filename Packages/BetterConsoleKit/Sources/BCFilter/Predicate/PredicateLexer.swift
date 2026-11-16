import Foundation

/// A token of predicate text with its source range.
struct PredicateToken: Sendable {
    enum Kind: Equatable, Sendable {
        /// A word: a key, a keyword (`AND`, `CONTAINS`, …) or a bare value (`error`).
        case word(String)
        /// A quoted string, escapes decoded.
        case string(String)
        /// A number as written (`500`, `0x1f`, `-1`).
        case number(String)
        /// Punctuation and operators: `( ) [ ] { } ,` and `== = != <> < <= =< > >= => && || !`.
        case symbol(String)
        /// `//` at the start of a line: a disabled condition follows.
        case disabledStart
        /// The end of a `//` line (empty range at the line break or the end of the text).
        case disabledEnd
        /// Text that can't be a token; the parser reports `message` when it reaches it.
        case invalid(String)
        case end
    }

    var kind: Kind
    var range: Range<String.Index>
}

/// Splits predicate text into tokens (ES §6.1). Errors become `.invalid` tokens so they are
/// reported in text order, after anything wrong earlier in the text.
enum PredicateLexer {
    static let onlyDisabledCondition = "Only a disabled condition can follow // on its own line"

    static func tokens(_ text: String) -> [PredicateToken] {
        let s = text.unicodeScalars
        var tokens: [PredicateToken] = []
        tokens.reserveCapacity(s.count / 4)
        var i = s.startIndex
        var atLineStart = true
        var inDisabledLine = false

        func add(_ kind: PredicateToken.Kind, _ from: String.Index, _ to: String.Index) {
            tokens.append(PredicateToken(kind: kind, range: from..<to))
        }
        func lineEnd(from j: String.Index) -> String.Index {
            var j = j
            while j < s.endIndex, s[j] != "\n", s[j] != "\r" { j = s.index(after: j) }
            return j
        }
        func peek(_ j: String.Index) -> Unicode.Scalar? {
            let n = s.index(after: j)
            return n < s.endIndex ? s[n] : nil
        }

        while i < s.endIndex {
            let ch = s[i]
            let start = i
            if ch == "\n" || ch == "\r" {
                if inDisabledLine {
                    add(.disabledEnd, i, i)
                    inDisabledLine = false
                }
                atLineStart = true
                i = s.index(after: i)
                continue
            }
            if ch.properties.isWhitespace {
                i = s.index(after: i)
                continue
            }
            if ch == "/", peek(i) == "/" {
                if atLineStart, !inDisabledLine {
                    i = s.index(i, offsetBy: 2)
                    add(.disabledStart, start, i)
                    inDisabledLine = true
                } else {
                    i = lineEnd(from: i)
                    add(.invalid(onlyDisabledCondition), start, i)
                }
                atLineStart = false
                continue
            }
            atLineStart = false

            if ch == "\"" || ch == "'" {
                i = s.index(after: i)
                var value = String.UnicodeScalarView()
                var closed = false
                var badEscape: String.Index?
                while i < s.endIndex {
                    let c = s[i]
                    if c == ch { closed = true; i = s.index(after: i); break }
                    if c == "\n" || c == "\r" { break }
                    if c == "\\" {
                        let n = s.index(after: i)
                        guard n < s.endIndex, s[n] != "\n", s[n] != "\r" else { i = n; continue }
                        switch s[n] {
                        case "n": value.append("\n")
                        case "r": value.append("\r")
                        case "t": value.append("\t")
                        case "u":
                            guard let (scalar, after) = unicodeEscape(s, at: i) else {
                                badEscape = badEscape ?? i
                                i = s.index(after: n)
                                continue
                            }
                            value.append(scalar)
                            i = after
                            continue
                        default:
                            // As in NSPredicate, any other escaped character stands for itself
                            // (`"com\.apple"` is `com.apple`).
                            value.append(s[n])
                        }
                        i = s.index(after: n)
                        continue
                    }
                    value.append(c)
                    i = s.index(after: i)
                }
                if !closed {
                    add(.invalid("Unterminated string"), start, i)
                } else if badEscape != nil {
                    add(.invalid("Expected four hex digits after \\u"), start, i)
                } else {
                    add(.string(String(value)), start, i)
                }
                continue
            }

            if isDigit(ch) || (ch == "-" && peek(i).map(isDigit) == true) {
                i = s.index(after: i)
                while i < s.endIndex, isWordPart(s[i]) || s[i] == "." { i = s.index(after: i) }
                add(.number(String(s[start..<i])), start, i)
                continue
            }

            if ch.properties.isAlphabetic || ch == "_" {
                while i < s.endIndex, isWordPart(s[i]) { i = s.index(after: i) }
                add(.word(String(s[start..<i])), start, i)
                continue
            }

            if let next = peek(i) {
                let pair = String(ch) + String(next)
                if ["==", "!=", "<>", "<=", "=<", ">=", "=>", "&&", "||"].contains(pair) {
                    i = s.index(i, offsetBy: 2)
                    add(.symbol(pair), start, i)
                    continue
                }
            }
            if "()[]{},=<>!".unicodeScalars.contains(ch) {
                i = s.index(after: i)
                add(.symbol(String(ch)), start, i)
            } else {
                // The whole character, so an emoji sequence isn't split.
                let r = text.rangeOfComposedCharacterSequence(at: start)
                i = r.upperBound
                add(.invalid("Unexpected character ‘\(text[r])’"), r.lowerBound, r.upperBound)
            }
        }
        if inDisabledLine { add(.disabledEnd, s.endIndex, s.endIndex) }
        add(.end, s.endIndex, s.endIndex)
        return tokens
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

    /// Letters, digits, `_` and combining marks (so `cafe` + U+0301 stays one word).
    private static func isWordPart(_ c: Unicode.Scalar) -> Bool {
        if c.properties.isAlphabetic || isDigit(c) || c == "_" { return true }
        switch c.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// `\uXXXX` at `i` (the backslash), with a following `\uXXXX` low surrogate when the first
    /// is a high one: the scalar and the index after the escape; nil when it isn't valid.
    private static func unicodeEscape(
        _ s: String.UnicodeScalarView, at i: String.Index
    ) -> (Unicode.Scalar, String.Index)? {
        func hex4(_ j: String.Index) -> (UInt32, String.Index)? {
            // `j` is the backslash of `\uXXXX`.
            var k = j
            for expected in ["\\", "u"] as [Unicode.Scalar] {
                guard k < s.endIndex, s[k] == expected else { return nil }
                k = s.index(after: k)
            }
            var v: UInt32 = 0
            for _ in 0..<4 {
                guard k < s.endIndex, let d = Character(s[k]).hexDigitValue else { return nil }
                v = v * 16 + UInt32(d)
                k = s.index(after: k)
            }
            return (v, k)
        }
        guard let (first, after) = hex4(i) else { return nil }
        if (0xD800...0xDBFF).contains(first) {
            guard let (second, end) = hex4(after), (0xDC00...0xDFFF).contains(second) else { return nil }
            return Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)).map { ($0, end) }
        }
        return Unicode.Scalar(first).map { ($0, after) }
    }
}
