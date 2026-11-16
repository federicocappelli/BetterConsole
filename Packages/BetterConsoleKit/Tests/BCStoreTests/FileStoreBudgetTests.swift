import Foundation
import Testing
import BCModel
@testable import BCStore

/// Opened files' stores give way last: live stores are evicted first (oldest across them),
/// and a file store only once no live store has entries left.
@MainActor
struct FileStoreBudgetTests {
    private func fill(_ ids: [UInt64], into s: RingBufferLogStore) {
        s.append(contentsOf: ids.map { makeEntry($0, t: Double($0)) })
    }
    private func ids(_ s: RingBufferLogStore) -> [UInt64] { (0..<s.count).map { s[$0].id } }

    /// A live store at the limit, then an older file loads: the file keeps everything and the
    /// live store shrinks.
    @Test func liveStoresAreEvictedBeforeAnOlderFile() {
        let per = makeEntry(1).estimatedBytes
        let live = RingBufferLogStore(), file = RingBufferLogStore()
        let budget = MemoryBudget(limitBytes: per * 6)
        budget.register(live)
        fill([100, 101, 102, 103, 104, 105], into: live)
        budget.enforce()
        #expect(live.count == 6)
        budget.register(file, isFile: true)
        fill([1, 2, 3], into: file)
        budget.enforce()
        #expect(ids(file) == [1, 2, 3])
        #expect(ids(live) == [103, 104, 105])
    }

    /// With two live stores the oldest across them goes first, as before.
    @Test func oldestAcrossLiveStoresFirst() {
        let per = makeEntry(1).estimatedBytes
        let a = RingBufferLogStore(), b = RingBufferLogStore(), file = RingBufferLogStore()
        let budget = MemoryBudget(limitBytes: per * 4)
        budget.register(a); budget.register(b); budget.register(file, isFile: true)
        fill([10, 30], into: a)
        fill([20, 40], into: b)
        fill([1, 2], into: file)
        budget.enforce()
        #expect(ids(file) == [1, 2])
        #expect(ids(a) == [30])
        #expect(ids(b) == [40])
    }

    /// No live entries left: the files' own oldest go, oldest across files.
    @Test func filesGiveWayOnlyWhenNoLiveEntriesRemain() {
        let per = makeEntry(1).estimatedBytes
        let live = RingBufferLogStore(), f1 = RingBufferLogStore(), f2 = RingBufferLogStore()
        let budget = MemoryBudget(limitBytes: per * 3)
        budget.register(live); budget.register(f1, isFile: true); budget.register(f2, isFile: true)
        fill([50], into: live)
        fill([1, 3, 5], into: f1)
        fill([2, 4], into: f2)
        budget.enforce()
        #expect(live.count == 0)
        #expect(ids(f1) == [3, 5])
        #expect(ids(f2) == [4])
    }
}
