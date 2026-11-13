import Foundation
import Testing
@testable import BCTransport

@Suite struct LineSplitterTests {
    private static func data(_ string: String) -> Data { Data(string.utf8) }

    @Test func splitsAcrossChunkBoundaries() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Self.data("ab")) == [])
        #expect(splitter.feed(Self.data("c\nde")) == [Self.data("abc")])
        #expect(splitter.feed(Self.data("f\n")) == [Self.data("def")])
    }

    @Test func multipleLinesInOneChunk() {
        var splitter = LineSplitter()
        let lines = splitter.feed(Self.data("one\ntwo\nthree\npart"))
        #expect(lines == [Self.data("one"), Self.data("two"), Self.data("three")])
        #expect(splitter.finish() == Self.data("part"))
    }

    @Test func emptyLinesDropped() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Self.data("\n\n")) == [])
        #expect(splitter.feed(Self.data("\na\n\n")) == [Self.data("a")])
    }

    @Test func finishReturnsPartial() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Self.data("xyz")) == [])
        #expect(splitter.finish() == Self.data("xyz"))
    }

    @Test func finishReturnsNilWhenNothingBuffered() {
        var splitter = LineSplitter()
        #expect(splitter.finish() == nil)
        #expect(splitter.feed(Self.data("a\n")) == [Self.data("a")])
        #expect(splitter.finish() == nil)
    }

    @Test func finishClearsBuffer() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Self.data("stale")) == [])
        #expect(splitter.finish() == Self.data("stale"))
        #expect(splitter.feed(Self.data("fresh\n")) == [Self.data("fresh")])
    }

    @Test func byteExactAcrossUTF8Split() {
        // U+1F600 (😀) is four UTF-8 bytes: F0 9F 98 80. Split it across two chunks.
        let emoji = Array("😀".utf8)
        #expect(emoji.count == 4)
        var splitter = LineSplitter()
        #expect(splitter.feed(Data(Array("hi ".utf8) + emoji[0..<2])) == [])
        let lines = splitter.feed(Data(emoji[2..<4] + Array("!\n".utf8)))
        #expect(lines.count == 1)
        #expect(Array(lines[0]) == Array("hi 😀!".utf8))
    }
}

@Suite struct LineSplitterMaxLengthTests {
    private static func data(_ string: String) -> Data { Data(string.utf8) }

    @Test func dropsOverlongPartialLine() {
        var splitter = LineSplitter(maxLineLength: 4)
        #expect(splitter.feed(Self.data("ok\nabc")) == [Self.data("ok")])
        // Partial grows past the limit: discarded, and its tail is dropped up to the newline.
        #expect(splitter.feed(Self.data("defg")) == [])
        #expect(splitter.feed(Self.data("hij\nnext\n")) == [Self.data("next")])
        #expect(splitter.finish() == nil)
    }

    @Test func overlongPartialNotReturnedByFinish() {
        var splitter = LineSplitter(maxLineLength: 3)
        #expect(splitter.feed(Self.data("abcdef")) == [])
        #expect(splitter.finish() == nil)
        #expect(splitter.feed(Self.data("x\n")) == [Self.data("x")])
    }

    @Test func partialAtLimitKept() {
        var splitter = LineSplitter(maxLineLength: 3)
        #expect(splitter.feed(Self.data("abc")) == [])
        #expect(splitter.feed(Self.data("\n")) == [Self.data("abc")])
    }

    @Test func completeLinesLongerThanLimitInOneChunkStillEmitted() {
        // The limit bounds buffered memory, not line length within a chunk already in memory.
        var splitter = LineSplitter(maxLineLength: 3)
        #expect(splitter.feed(Self.data("abcdef\n")) == [Self.data("abcdef")])
    }

    @Test func consumedBytesDoNotStayInTheBuffer() {
        // `Data.removeFirst` only re-slices: the buffer kept every byte ever fed (1.3 GB after
        // a minute of 20k msgs/s). Consumed bytes must leave the buffer's storage.
        var splitter = LineSplitter()
        for i in 0..<1_000 {
            #expect(splitter.feed(Self.data("line \(i)\npart")) == [Self.data(i == 0 ? "line 0" : "partline \(i)")])
            #expect(splitter.bufferStorageOffset == 0)
        }
        #expect(splitter.finish() == Self.data("part"))
    }
}
