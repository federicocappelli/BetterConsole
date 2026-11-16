import Foundation

/// Converts between the text view's UTF-16 offsets and indices of the model's own string.
/// Model ranges must be converted against the model's string: indices from the text view's
/// bridged string don't compare correctly with them after a non-ASCII character.
enum PredicateTextMapping {
    static func index(utf16Offset offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        return String.Index(utf16Offset: offset, in: text)
    }

    static func nsRange(_ range: Range<String.Index>, in text: String) -> NSRange? {
        guard range.upperBound <= text.endIndex else { return nil }
        return NSRange(range, in: text)
    }
}
