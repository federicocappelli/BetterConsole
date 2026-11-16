import Foundation
import Testing
import BCFilter
import BCModel
import BCStore
import BCTransport
@testable import BCStreaming

/// Save Logs: the rows shown when Save is chosen, gathered in chunks through a real
/// `StreamSession`. Entry `i` is streamed `i`-th (position `i`, date `i`); processes cycle
/// A, B, C.
@MainActor
struct RowSnapshotTests {
    let transport = FakeTransport()

    func streamed(_ total: Int = 10_000, budget: MemoryBudget = MemoryBudget()) async -> StreamSession {
        let s = StreamSession(
            device: mac, transport: transport, budget: budget, drainInterval: .milliseconds(5))
        s.maxRescanChunk = 1_000
        s.start()
        stream(0..<total)
        #expect(await settle(s, total: total))
        return s
    }

    func stream(_ range: Range<Int>) {
        let processes = ["A", "B", "C"]
        var low = range.lowerBound
        while low < range.upperBound {
            let high = min(low + 1_000, range.upperBound)
            transport.yield((low..<high).map { makeEntry(UInt64($0), process: processes[$0 % 3]) })
            low = high
        }
    }

    func settle(_ s: StreamSession, total: Int) async -> Bool {
        await eventually(timeout: .seconds(5)) { s.appendedCount == total && !s.isFiltering }
    }

    func processIs(_ value: String) -> FilterExpression {
        .condition(FilterCondition(field: .process, match: .is, value: value))
    }

    /// Original indices of the gathered entries, chunk by chunk.
    func gather(_ s: StreamSession, _ snapshot: RowSnapshot) async -> [[Int]]? {
        await s.mapEntries(of: snapshot) { $0.map { Int($0.date.timeIntervalSince1970) } }
    }

    @Test func everyRowInOrderInChunks() async {
        let s = await streamed()
        let snapshot = s.rows.snapshot()
        #expect(snapshot.count == 10_000)
        let chunks = await gather(s, snapshot)
        #expect(chunks?.map(\.count) == Array(repeating: 1_000, count: 10))
        #expect(chunks?.flatMap { $0 } == Array(0..<10_000))
    }

    /// Filtered: the matching rows when Save was chosen, even if the filter changes and new
    /// rows arrive before they are gathered.
    @Test func filteredSnapshotIgnoresLaterChanges() async {
        let s = await streamed()
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        let snapshot = s.rows.snapshot()
        #expect(snapshot.count == 3_334)
        s.setFilter(processIs("B"))
        stream(10_000..<10_300)
        #expect(await settle(s, total: 10_300))
        let chunks = await gather(s, snapshot)
        #expect(chunks?.flatMap { $0 } == Array(stride(from: 0, to: 10_000, by: 3)))
    }

    /// Rows that arrive after Save is chosen are not included.
    @Test func laterRowsAreLeftOut() async {
        let s = await streamed()
        let snapshot = s.rows.snapshot()
        stream(10_000..<10_500)
        #expect(await settle(s, total: 10_500))
        #expect(await gather(s, snapshot)?.flatMap { $0 } == Array(0..<10_000))
    }

    /// Rows evicted while the save is under way are skipped (unfiltered and filtered).
    @Test func rowsEvictedMidSaveAreSkipped() async {
        let budget = MemoryBudget()
        let s = await streamed(budget: budget)
        let perEntry = s.store.estimatedBytes / s.store.count
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            if copies == 2 { budget.limitBytes = perEntry * 5_000 }  // evicts 0..<5,000
        }
        let chunks = await gather(s, s.rows.snapshot())
        #expect(chunks?.flatMap { $0 } == Array(0..<2_000) + Array(5_000..<10_000))
    }

    @Test func filteredRowsEvictedMidSaveAreSkipped() async {
        let budget = MemoryBudget()
        let s = await streamed(budget: budget)
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        let perEntry = s.store.estimatedBytes / s.store.count
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            if copies == 1 { budget.limitBytes = perEntry * 4_000 }  // evicts 0..<6,000
        }
        let chunks = await gather(s, s.rows.snapshot())
        #expect(
            chunks?.flatMap { $0 }
                == Array(stride(from: 0, to: 3_000, by: 3)) + Array(stride(from: 6_000, to: 10_000, by: 3)))
    }

    /// Clear during the save: what was gathered before it, nothing after.
    @Test func clearMidSaveStopsTheRest() async {
        let s = await streamed()
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            if copies == 3 { s.clear() }
        }
        #expect(await gather(s, s.rows.snapshot())?.flatMap { $0 } == Array(0..<3_000))
    }

    /// Slow copies shrink the chunk (each main-actor step stays short).
    @Test func slowCopiesShrinkTheChunk() async {
        let s = await streamed()
        s.copyDurationOverride = .milliseconds(10)
        let chunks = await gather(s, s.rows.snapshot())
        #expect(chunks?.first?.count == 1_000)
        #expect(chunks?.dropFirst().allSatisfy { $0.count == StreamSession.minRescanChunk } == true)
        #expect(chunks?.flatMap { $0 } == Array(0..<10_000))
    }

    @Test func emptySessionGathersNothing() async {
        let s = StreamSession(device: mac, transport: transport, budget: MemoryBudget())
        #expect(s.rows.snapshot().count == 0)
        #expect(await gather(s, s.rows.snapshot()) == [])
    }

    @Test func cancelledSaveReturnsNil() async {
        let s = await streamed()
        let snapshot = s.rows.snapshot()
        let task = Task { @MainActor in await s.mapEntries(of: snapshot) { $0.count } }
        task.cancel()
        #expect(await task.value == nil)
    }
}
