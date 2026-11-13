import Foundation
import Testing
import BCModel
@testable import BCStore

func makeEntry(_ id: UInt64, t: TimeInterval? = nil, message: String = "m") -> LogEntry {
    LogEntry(id: id, date: Date(timeIntervalSince1970: t ?? Double(id)), level: .info,
             eventType: "logEvent", process: "p", message: message)
}

@MainActor
struct RingBufferLogStoreTests {
    @Test func appendAndIndexInOrder() {
        let s = RingBufferLogStore()
        s.append(contentsOf: (1...5).map { makeEntry(UInt64($0)) })
        #expect(s.count == 5)
        #expect((0..<5).map { s[$0].id } == [1, 2, 3, 4, 5])
        #expect(s.oldestDate == Date(timeIntervalSince1970: 1))
    }

    @Test func removedCountCountsEvictionsAndClears() {
        // Lets the table map its rows onto the store in O(1) after evictions.
        let s = RingBufferLogStore()
        #expect(s.removedCount == 0)
        s.append(contentsOf: (1...10).map { makeEntry(UInt64($0)) })
        s.removeOldest(3)
        #expect(s.removedCount == 3)
        s.removeOldest(100)  // clamps to the 7 left
        #expect(s.removedCount == 10)
        s.append(contentsOf: (11...14).map { makeEntry(UInt64($0)) })
        s.removeAll()
        #expect(s.removedCount == 14)
        s.removeOldest(1)  // nothing left
        #expect(s.removedCount == 14)
    }

    @Test func removeOldestShiftsIndices() {
        let s = RingBufferLogStore()
        s.append(contentsOf: (1...10).map { makeEntry(UInt64($0)) })
        s.removeOldest(3)
        #expect(s.count == 7)
        #expect(s[0].id == 4)
    }

    @Test func bytesTrackAppendAndRemove() {
        let s = RingBufferLogStore()
        let es = (1...4).map { makeEntry(UInt64($0), message: String(repeating: "x", count: $0 * 10)) }
        s.append(contentsOf: es)
        #expect(s.estimatedBytes == es.reduce(0) { $0 + $1.estimatedBytes })
        s.removeOldest(2)
        #expect(s.estimatedBytes == es[2].estimatedBytes + es[3].estimatedBytes)
    }

    @Test func removeAllResets() {
        let s = RingBufferLogStore()
        s.append(contentsOf: (1...5).map { makeEntry(UInt64($0)) })
        s.removeAll()
        #expect(s.count == 0)
        #expect(s.estimatedBytes == 0)
        #expect(s.oldestDate == nil)
        s.append(contentsOf: [makeEntry(9)])
        #expect(s[0].id == 9)
    }

    @Test func wrapsAndGrowsFromContiguous() {
        let s = RingBufferLogStore(initialCapacity: 4)
        func ids() -> [UInt64] { (0..<s.count).map { s[$0].id } }
        func bytes(_ r: ClosedRange<UInt64>) -> Int { r.reduce(0) { $0 + makeEntry($1).estimatedBytes } }
        s.append(contentsOf: (1...3).map { makeEntry(UInt64($0)) })
        s.removeOldest(2)
        #expect(ids() == [3])
        #expect(s.estimatedBytes == bytes(3...3))
        s.append(contentsOf: (4...7).map { makeEntry(UInt64($0)) }) // grows from contiguous data
        #expect(ids() == [3, 4, 5, 6, 7])
        #expect(s.estimatedBytes == bytes(3...7))
        s.append(contentsOf: (8...20).map { makeEntry(UInt64($0)) }) // grows while wrapped
        #expect(ids() == Array(3...20))
        #expect(s.estimatedBytes == bytes(3...20))
        #expect(s.oldestDate == Date(timeIntervalSince1970: 3))
        s.removeOldest(10)
        s.append(contentsOf: (21...40).map { makeEntry(UInt64($0)) })
        #expect(ids() == Array(13...40))
        #expect(s.estimatedBytes == bytes(13...40))
    }

    @Test func growsWhileWrappedAcrossTwoSegments() {
        let s = RingBufferLogStore(initialCapacity: 4)
        func ids() -> [UInt64] { (0..<s.count).map { s[$0].id } }
        func bytes(_ r: ClosedRange<UInt64>) -> Int { r.reduce(0) { $0 + makeEntry($1).estimatedBytes } }
        s.append(contentsOf: (1...4).map { makeEntry(UInt64($0)) })
        #expect(ids() == [1, 2, 3, 4])
        #expect(s.estimatedBytes == bytes(1...4))
        s.removeOldest(2)
        #expect(ids() == [3, 4])
        #expect(s.estimatedBytes == bytes(3...4))
        s.append(contentsOf: (5...6).map { makeEntry(UInt64($0)) }) // head 2, count 4: wrapped, full
        #expect(ids() == [3, 4, 5, 6])
        #expect(s.estimatedBytes == bytes(3...6))
        s.append(contentsOf: [makeEntry(7)]) // grows with two segments (first 2 < count 4)
        #expect(ids() == [3, 4, 5, 6, 7])
        #expect(s.estimatedBytes == bytes(3...7))
        #expect(s.oldestDate == Date(timeIntervalSince1970: 3))
        s.removeOldest(5)
        #expect(s.count == 0 && s.estimatedBytes == 0)
    }

    @Test func removeOldestClampsToCount() {
        let s = RingBufferLogStore()
        s.append(contentsOf: (1...3).map { makeEntry(UInt64($0)) })
        s.removeOldest(10)
        #expect(s.count == 0)
        #expect(s.estimatedBytes == 0)
        s.removeOldest(0)
        s.removeOldest(-1)
        #expect(s.count == 0)
    }
}
