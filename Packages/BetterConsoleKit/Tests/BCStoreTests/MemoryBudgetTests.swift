import Foundation
import Testing
import BCModel
@testable import BCStore

@MainActor
struct MemoryBudgetTests {
    private func fill(_ ids: [UInt64], into s: RingBufferLogStore) {
        s.append(contentsOf: ids.map { makeEntry($0, t: Double($0)) })
    }

    @Test func evictsOldestAcrossStores() {
        let a = RingBufferLogStore(), b = RingBufferLogStore()
        fill([1, 3, 5], into: a)
        fill([2, 4, 6], into: b)
        let budget = MemoryBudget(limitBytes: makeEntry(1).estimatedBytes * 3)
        budget.register(a); budget.register(b)
        budget.enforce()
        #expect((0..<a.count).map { a[$0].id } == [5])
        #expect((0..<b.count).map { b[$0].id } == [4, 6])
    }

    @Test func loweringLimitEvictsImmediately() {
        let a = RingBufferLogStore()
        fill([1, 2, 3, 4], into: a)
        let per = makeEntry(1).estimatedBytes
        let budget = MemoryBudget(limitBytes: per * 10)
        budget.register(a)
        budget.enforce()
        #expect(a.count == 4)
        budget.limitBytes = per * 2
        #expect(a.count == 2)
        #expect(a[0].id == 3)
    }

    @Test func underLimitNoEviction() {
        let a = RingBufferLogStore()
        fill([1, 2, 3], into: a)
        let budget = MemoryBudget()
        budget.register(a)
        budget.enforce()
        #expect(a.count == 3)
        #expect(MemoryBudget.defaultLimit == 4 * 1024 * 1024 * 1024)
    }

    @Test func unregisteredStoreIgnored() {
        let a = RingBufferLogStore(), b = RingBufferLogStore()
        fill([1, 2, 3], into: a)
        fill([4, 5, 6], into: b)
        let budget = MemoryBudget(limitBytes: makeEntry(1).estimatedBytes * 3)
        budget.register(a); budget.register(b)
        budget.unregister(a)
        budget.enforce()
        #expect(a.count == 3)
        #expect(b.count == 3)
        budget.limitBytes = makeEntry(1).estimatedBytes
        #expect(a.count == 3)
        #expect(b.count == 1)
    }

    @Test func releasedStoreIsDropped() {
        let per = makeEntry(1).estimatedBytes
        let budget = MemoryBudget(limitBytes: per)
        let live = RingBufferLogStore()
        fill([10, 11, 12], into: live)
        var gone: RingBufferLogStore? = RingBufferLogStore()
        fill([1, 2, 3], into: gone!)
        budget.register(live)
        budget.register(gone!)
        #expect(budget.registeredCount == 2)
        gone = nil
        #expect(budget.registeredCount == 1)
        budget.enforce()
        #expect(live.count == 1)
        #expect(live[0].id == 12)
        #expect(budget.registeredCount == 1)
    }

    @Test func massEvictionIsFastAndCorrect() {
        let s = RingBufferLogStore()
        s.append(contentsOf: (0..<200_000).map { makeEntry(UInt64($0)) })
        let per = makeEntry(0).estimatedBytes
        let budget = MemoryBudget(limitBytes: per * 300_000)
        budget.register(s)
        let start = ContinuousClock.now
        budget.limitBytes = per * 1_000
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(100))
        #expect(s.count == 1_000)
        #expect(s[0].id == 199_000)
        #expect(s.estimatedBytes == per * 1_000)
    }

    @Test func largeChunkedEvictionStopsAtLimit() {
        let a = RingBufferLogStore(), b = RingBufferLogStore()
        a.append(contentsOf: (0..<5000).map { makeEntry(UInt64($0), t: Double($0) * 2) })
        b.append(contentsOf: (0..<5000).map { makeEntry(UInt64($0), t: Double($0) * 2 + 1) })
        let per = makeEntry(0).estimatedBytes
        let budget = MemoryBudget(limitBytes: per * 3000)
        budget.register(a); budget.register(b)
        budget.enforce()
        #expect(a.count + b.count == 3000)
        // remaining are the newest 3000 interleaved: 1500 each
        #expect(a.count == 1500 && b.count == 1500)
    }

    @Test func evictionCallbackFiresOncePerPassForEvictedStoresOnly() {
        let a = RingBufferLogStore(), b = RingBufferLogStore(), c = RingBufferLogStore()
        // Many chunks from `a` in one pass (more than the 1,000-entry chunk size).
        a.append(contentsOf: (0..<3000).map { makeEntry(UInt64($0), t: Double($0)) })
        fill([5000, 5001], into: b)
        fill([6000], into: c)
        let per = makeEntry(0).estimatedBytes
        let budget = MemoryBudget(limitBytes: per * 10_000)
        var calls: [String: Int] = [:]
        budget.register(a) { calls["a", default: 0] += 1 }
        budget.register(b) { calls["b", default: 0] += 1 }
        budget.register(c) { calls["c", default: 0] += 1 }
        budget.enforce()
        #expect(calls.isEmpty)  // under the limit: no callbacks
        budget.limitBytes = per * 3  // one pass: evicts all of a's 3000 entries
        #expect(calls == ["a": 1])
        #expect(a.count == 0 && b.count == 2 && c.count == 1)
        budget.limitBytes = per * 1  // next pass evicts b's two entries, keeps c
        #expect(calls == ["a": 1, "b": 1])
        #expect(b.count == 0 && c.count == 1)
    }

    @Test func reRegisteringReplacesCallback() {
        let a = RingBufferLogStore()
        fill([1, 2], into: a)
        let budget = MemoryBudget(limitBytes: makeEntry(1).estimatedBytes * 10)
        var first = 0, second = 0
        budget.register(a) { first += 1 }
        budget.register(a) { second += 1 }
        budget.limitBytes = makeEntry(1).estimatedBytes
        #expect(first == 0 && second == 1)
        #expect(budget.registeredCount == 1)
    }
}
