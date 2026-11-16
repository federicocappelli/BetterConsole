import Foundation
import Testing
import BCFilter

@Suite struct PredicateTextMappingTests {
    /// Offsets from the NSTextView (UTF-16) map into the model's own string, so a click after
    /// a non-ASCII character finds the right row.
    @Test func clickAfterNonASCIIFindsTheRightNode() throws {
        let text = #"eventMessage == "café" AND process == "x""#
        let parsed = try PredicateParser.parseWithRanges(text, linkForName: { _ in .notFound }).get()
        let processRange = try #require(parsed.text.nodeRanges[[1]])
        let ns = text as NSString
        let click = ns.range(of: "process").location
        let index = try #require(PredicateTextMapping.index(utf16Offset: click, in: text))
        #expect(processRange.contains(index))
        #expect(!(parsed.text.nodeRanges[[0]]?.contains(index) ?? false))
        #expect(PredicateTextMapping.nsRange(processRange, in: text) == ns.range(of: #"process == "x""#))
    }

    @Test func outOfRange() {
        #expect(PredicateTextMapping.index(utf16Offset: 99, in: "abc") == nil)
        #expect(PredicateTextMapping.index(utf16Offset: 3, in: "abc") == "abc".endIndex)
        let other = "a long string"
        let range = other.index(other.startIndex, offsetBy: 5)..<other.endIndex
        #expect(PredicateTextMapping.nsRange(range, in: "abc") == nil)
    }
}
