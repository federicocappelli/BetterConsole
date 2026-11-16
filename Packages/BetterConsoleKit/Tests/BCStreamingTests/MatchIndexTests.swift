import Testing
import Foundation
import BCModel
import BCStore
@testable import BCStreaming

@Suite struct MatchIndexTests {
    private func rows(_ index: MatchIndex) -> [Int] { (0..<index.count).map { index[$0] } }

    @Test func appendAndLookup() {
        var index = MatchIndex()
        for p in [3, 5, 8] { index.append(p) }
        #expect(index.count == 3)
        #expect(rows(index) == [3, 5, 8])
        #expect(index.row(forPosition: 5) == 1)
        #expect(index.row(forPosition: 4) == nil)
        #expect(index.row(forPosition: 9) == nil)
    }

    @Test func prependNewestFirst() {
        var index = MatchIndex()
        index.append(12)
        index.prepend([9, 7, 4])
        #expect(rows(index) == [4, 7, 9, 12])
        #expect(index.row(forPosition: 7) == 1)
        #expect(index.row(forPosition: 12) == 3)
        index.prepend([2, 1])
        #expect(rows(index) == [1, 2, 4, 7, 9, 12])
    }

    @Test func dropBelow() {
        var index = MatchIndex()
        index.append(20)
        index.append(30)
        index.prepend([9, 7, 4])
        #expect(index.dropBelow(5) == 1)
        #expect(rows(index) == [7, 9, 20, 30])
        // Across both halves.
        #expect(index.dropBelow(25) == 3)
        #expect(rows(index) == [30])
        #expect(index.dropBelow(0) == 0)
        #expect(index.dropBelow(100) == 1)
        #expect(index.count == 0)
        index.append(101)
        #expect(rows(index) == [101])
    }

    @Test func rowAtOrBefore() {
        var index = MatchIndex()
        index.append(10)
        index.append(20)
        index.prepend([5])
        #expect(index.row(atOrBefore: 4) == nil)
        #expect(index.row(atOrBefore: 5) == 0)
        #expect(index.row(atOrBefore: 9) == 0)
        #expect(index.row(atOrBefore: 10) == 1)
        #expect(index.row(atOrBefore: 15) == 1)
        #expect(index.row(atOrBefore: 99) == 2)
        #expect(MatchIndex().row(atOrBefore: 3) == nil)
    }

    @Test func newerCompactionKeepsRowsAndLookups() {
        var index = MatchIndex()
        for p in 0..<2_500 { index.append(p * 2) }
        #expect(index.dropBelow(2_200 * 2) == 2_200)  // > 1,024 and more than half of newer
        #expect(index.count == 300)
        #expect(index[0] == 4_400)
        #expect(index[299] == 4_998)
        #expect(index.row(forPosition: 4_400) == 0)
        #expect(index.row(forPosition: 4_401) == nil)
        #expect(index.row(atOrBefore: 4_399) == nil)
        #expect(index.row(atOrBefore: 4_999) == 299)
        index.append(5_000)
        #expect(index.count == 301)
        #expect(index[300] == 5_000)
        #expect(index.row(forPosition: 5_000) == 300)
    }

    @Test func prependAfterPartialNewerDrop() {
        var index = MatchIndex()
        for p in [10, 20, 30, 40] { index.append(p) }
        #expect(index.dropBelow(25) == 2)
        index.prepend([28, 26])
        #expect(rows(index) == [26, 28, 30, 40])
        #expect(index.row(forPosition: 28) == 1)
        #expect(index.dropBelow(29) == 2)
        #expect(rows(index) == [30, 40])
    }

    @Test func prependIntoEmptyGuardsLaterAppend() async {
        await #expect(processExitsWith: .failure) {
            var index = MatchIndex()
            index.prepend([9, 7])
            index.append(8)
        }
    }

    @Test func removeAll() {
        var index = MatchIndex()
        index.append(1)
        index.prepend([0])
        index.removeAll()
        #expect(index.count == 0)
        index.append(7)
        #expect(rows(index) == [7])
    }

    @Test func largeIndexPerformance() {
        var index = MatchIndex()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for p in 0..<1_000_000 { index.append(p) }
            for k in 1...1_000 { _ = index.dropBelow(k) }
        }
        #expect(index.count == 999_000)
        #expect(index[0] == 1_000)
        #expect(elapsed < .milliseconds(200))
    }
}

@MainActor @Suite struct LogRowsDirectTests {
    @Test func directModeMapsRowsToStoreAcrossEviction() {
        let store = RingBufferLogStore()
        store.append(contentsOf: makeEntries(0..<10))
        let rows = LogRows(store: store)
        #expect(!rows.isFiltered)
        #expect(rows.count == 10)
        #expect(rows.position(ofRow: 0) == 0)
        #expect(rows[3].id == 3)
        #expect(rows.row(forPosition: 7) == 7)
        #expect(rows.row(forPosition: 10) == nil)

        store.removeOldest(4)
        #expect(rows.count == 6)
        #expect(rows.removedFromFront == 4)
        #expect(rows[0].id == 4)
        #expect(rows.position(ofRow: 0) == 4)
        #expect(rows.row(forPosition: 3) == nil)
        #expect(rows.row(forPosition: 4) == 0)
        #expect(rows.row(atOrBefore: 2) == nil)
        #expect(rows.row(atOrBefore: 6) == 2)
        #expect(rows.row(atOrBefore: 99) == 5)
    }

    @Test func filteredModeUsesIndex() {
        let store = RingBufferLogStore()
        store.append(contentsOf: makeEntries(0..<10))
        let rows = LogRows(store: store)
        var index = MatchIndex()
        for p in [2, 5, 8] { index.append(p) }
        rows.installFiltered(index)
        #expect(rows.isFiltered)
        #expect(rows.resetCount == 1)
        #expect(rows.count == 3)
        #expect(rows[1].id == 5)
        #expect(rows.position(ofRow: 2) == 8)
        #expect(rows.row(forPosition: 5) == 1)
        #expect(rows.row(atOrBefore: 7) == 1)
    }

    @Test func filteredMutatorsMoveCountersTogether() {
        let store = RingBufferLogStore()
        store.append(contentsOf: makeEntries(0..<20))
        let rows = LogRows(store: store)
        var index = MatchIndex()
        for p in [10, 12] { index.append(p) }
        rows.installFiltered(index)
        #expect(rows.resetCount == 1)

        rows.prependRescan([8, 6])
        #expect(rows.count == 4)
        #expect(rows.insertedAtFront == 2)
        #expect(rows.removedFromFront == 0)
        #expect(rows.position(ofRow: 0) == 6)

        rows.appendLive(15)
        #expect(rows.count == 5)
        #expect(rows.insertedAtFront == 2)
        #expect(rows.position(ofRow: 4) == 15)

        store.removeOldest(9)  // positions below 9 are gone: 6 and 8
        rows.dropEvicted()
        #expect(rows.count == 3)
        #expect(rows.removedFromFront == 2)
        #expect(rows.insertedAtFront == 2)
        #expect(rows[0].id == 10)
        #expect(rows.resetCount == 1)

        rows.clear()
        #expect(rows.isFiltered)
        #expect(rows.count == 0)
        #expect(rows.insertedAtFront == 0)
        #expect(rows.removedFromFront == 0)
        #expect(rows.resetCount == 2)

        rows.appendLive(15)
        rows.installUnfiltered()
        #expect(!rows.isFiltered)
        #expect(rows.count == store.count)
        #expect(rows.insertedAtFront == 0)
        #expect(rows.removedFromFront == 0)
        #expect(rows.resetCount == 3)
    }

    @Test func directModeMutatorsAndClear() {
        let store = RingBufferLogStore()
        store.append(contentsOf: makeEntries(0..<10))
        let rows = LogRows(store: store)
        store.removeOldest(3)
        rows.dropEvicted()  // no-op in direct mode
        #expect(rows.removedFromFront == 3)
        #expect(rows.count == 7)
        store.removeAll()
        rows.clear()
        #expect(rows.resetCount == 1)
        #expect(rows.removedFromFront == 0)
        #expect(rows.insertedAtFront == 0)
        #expect(rows.count == 0)
        store.append(contentsOf: makeEntries(10..<12))
        #expect(rows.count == 2)
        #expect(rows.position(ofRow: 0) == 10)
    }
}
