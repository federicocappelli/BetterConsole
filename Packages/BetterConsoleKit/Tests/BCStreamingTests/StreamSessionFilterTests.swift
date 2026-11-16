import Testing
import BCFilter
import BCModel
import BCStore
import BCTransport
@testable import BCStreaming

/// End-to-end filtering through a real `StreamSession`: entries come from `FakeTransport`, are
/// tagged off-main, drained into the store and index, and rescanned when the filter changes.
@MainActor
struct StreamSessionFilterTests {
    let transport = FakeTransport()

    func makeSession(budget: MemoryBudget = MemoryBudget()) -> StreamSession {
        StreamSession(
            device: mac, transport: transport, budget: budget, drainInterval: .milliseconds(5))
    }

    /// Entries whose process cycles through `processes` by id.
    func entries(_ range: Range<UInt64>, processes: [String] = ["A", "B", "C"]) -> [LogEntry] {
        range.map { makeEntry($0, process: processes[Int($0) % processes.count]) }
    }

    /// Yields `range` in batches of `batch`.
    func stream(_ range: Range<UInt64>, batch: UInt64 = 100) {
        var low = range.lowerBound
        while low < range.upperBound {
            let high = min(low + batch, range.upperBound)
            transport.yield(entries(low..<high))
            low = high
        }
    }

    func processIs(_ value: String) -> FilterExpression {
        .condition(FilterCondition(field: .process, match: .is, value: value))
    }

    func rowIDs(_ s: StreamSession) -> [UInt64] { (0..<s.rows.count).map { s.rows[$0].id } }

    /// Brute force: ids of the stored entries `expression` matches, oldest first.
    func expectedIDs(_ s: StreamSession, _ expression: FilterExpression?) -> [UInt64] {
        let filter = CompiledFilter(expression)
        return (0..<s.store.count).map { s.store[$0] }.filter(filter.matches).map(\.id)
    }

    /// Waits until `total` entries have been appended and no rescan is running.
    func settle(_ s: StreamSession, total: Int, timeout: Duration = .seconds(5)) async -> Bool {
        await eventually(timeout: timeout) { s.appendedCount == total && !s.isFiltering }
    }

    @Test func filterOnBeforeStreaming() async {
        let s = makeSession()
        s.setFilter(processIs("A"))
        #expect(!s.isFiltering)  // nothing stored yet, nothing to rescan
        s.start()
        transport.yield([makeEntry(0, process: "A"), makeEntry(1, process: "B"),
                         makeEntry(2, process: "A")])
        #expect(await settle(s, total: 3))
        #expect(s.rows.isFiltered)
        #expect(s.rows.count == 2)
        #expect((0..<s.rows.count).allSatisfy { s.rows[$0].process == "A" })
        #expect(s.store.count == 3)
    }

    @Test func filterAddedWhileStreaming() async {
        let s = makeSession()
        s.start()
        stream(0..<1_000)
        #expect(await settle(s, total: 1_000))
        let resets = s.rows.resetCount
        s.setFilter(processIs("A"))
        #expect(s.filter == processIs("A"))
        #expect(s.rows.resetCount == resets + 1)
        #expect(s.isFiltering)
        stream(1_000..<2_000)
        #expect(await settle(s, total: 2_000))
        let ids = rowIDs(s)
        #expect(ids == expectedIDs(s, processIs("A")))
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == 667)
        #expect(s.filterProgress == 1)
    }

    /// on > off > on, through the same running session.
    @Test func filterRemovedBringsEverythingBack() async {
        let s = makeSession()
        s.start()
        stream(0..<1_000)
        s.setFilter(processIs("A"))
        stream(1_000..<2_000)
        #expect(await settle(s, total: 2_000))
        #expect(s.rows.count == expectedIDs(s, processIs("A")).count)

        s.setFilter(nil)
        #expect(s.filter == nil)
        #expect(!s.isFiltering)
        #expect(!s.rows.isFiltered)
        #expect(s.rows.count == s.store.count)
        stream(2_000..<2_300)
        #expect(await settle(s, total: 2_300))
        #expect(s.rows.count == 2_300)
        #expect(rowIDs(s) == expectedIDs(s, nil))

        // And on again: the entries streamed while off are found by the rescan.
        s.setFilter(processIs("B"))
        #expect(await settle(s, total: 2_300))
        #expect(rowIDs(s) == expectedIDs(s, processIs("B")))
    }

    @Test func filterABA() async {
        let s = makeSession()
        s.start()
        stream(0..<500)
        s.setFilter(processIs("A"))
        stream(500..<1_000)
        s.setFilter(processIs("B"))
        stream(1_000..<1_500)
        s.setFilter(processIs("A"))
        stream(1_500..<2_000)
        #expect(await settle(s, total: 2_000))
        #expect(s.filter == processIs("A"))
        let ids = rowIDs(s)
        #expect(ids == expectedIDs(s, processIs("A")))
        #expect(Set(ids).count == ids.count)
    }

    @Test func settingTheSameFilterIsANoOp() async {
        let s = makeSession()
        s.start()
        stream(0..<300)
        #expect(await settle(s, total: 300))
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 300))
        let resets = s.rows.resetCount
        s.setFilter(processIs("A"))
        #expect(s.rows.resetCount == resets)
        #expect(!s.isFiltering)
        #expect(s.rows.count == 100)
    }

    @Test func changeDuringRescanLatestWins() async {
        let s = makeSession()
        s.start()
        stream(0..<200_000, batch: 10_000)
        #expect(await settle(s, total: 200_000, timeout: .seconds(10)))
        s.setFilter(processIs("A"))
        s.setFilter(processIs("B"))
        #expect(s.isFiltering)
        #expect(await settle(s, total: 200_000, timeout: .seconds(10)))
        #expect(!s.isFiltering)
        #expect(s.filter == processIs("B"))
        #expect(s.rows.count == expectedIDs(s, processIs("B")).count)
        #expect((0..<s.rows.count).allSatisfy { s.rows[$0].process == "B" })
        #expect(await eventually { s.runningRescans == 0 })
    }

    /// The budget evicts while a chunk is in flight (half of it goes), and the stream keeps
    /// appending and evicting afterwards, past rows the rescan already added: the index only
    /// ever holds live, matching positions.
    @Test func evictionDuringRescan() async {
        let budget = MemoryBudget()
        let s = makeSession(budget: budget)
        s.maxRescanChunk = 1_000
        s.start()
        stream(0..<30_000, batch: 1_000)
        #expect(await settle(s, total: 30_000))
        let perEntry = s.store.estimatedBytes / s.store.count  // every entry is the same size

        var copies = 0
        var removedDuringRescan = 0
        s.afterRescanCopy = {
            copies += 1
            guard copies == 3 else { return }  // chunk [27000, 28000) is in flight
            let before = s.store.removedCount
            budget.limitBytes = perEntry * (before + s.store.count - 27_500)
            removedDuringRescan = s.store.removedCount - before
        }
        s.setFilter(processIs("A"))
        stream(30_000..<31_000, batch: 250)  // drained while the rescan runs, or soon after
        #expect(await settle(s, total: 31_000))
        #expect(copies == 3)  // the rest of the range was evicted
        #expect(removedDuringRescan > 0)
        #expect(rowIDs(s) == expectedIDs(s, processIs("A")))
        // Later appends evict rows the rescan added (positions from 27,500 up).
        stream(31_000..<32_000, batch: 250)
        #expect(await settle(s, total: 32_000))
        #expect(s.store.removedCount >= 28_500)

        let removed = s.store.removedCount
        var rescanned = 0
        for r in 0..<s.rows.count {
            let p = s.rows.position(ofRow: r)
            #expect(p >= removed && p < removed + s.store.count)
            #expect(s.rows[r].process == "A")
            if p < 30_000 { rescanned += 1 }
        }
        #expect(rescanned > 0)
        #expect(rowIDs(s) == expectedIDs(s, processIs("A")))
    }

    @Test func clearDuringRescan() async {
        let s = makeSession()
        s.maxRescanChunk = 1_000
        s.start()
        stream(0..<10_000, batch: 1_000)
        #expect(await settle(s, total: 10_000))
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            if copies == 2 { s.clear() }
        }
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        #expect(copies == 2)  // nothing left to scan after the clear
        #expect(s.store.count == 0)
        #expect(s.rows.count == 0)
        #expect(s.rows.isFiltered)

        stream(10_000..<10_030)
        #expect(await settle(s, total: 10_030))
        #expect(s.rows.count == 10)
        #expect(rowIDs(s) == expectedIDs(s, processIs("A")))
    }

    /// Runs a chunked rescan of 10,000 entries and calls `change` once the second chunk is
    /// in flight; then checks the session shows everything again, with no rescan left.
    func expectEverythingBackAfterChangeMidRescan(
        _ change: @escaping (StreamSession) -> Void
    ) async {
        let s = makeSession()
        s.maxRescanChunk = 1_000
        s.start()
        stream(0..<10_000, batch: 1_000)
        #expect(await settle(s, total: 10_000))
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            if copies == 2 { change(s) }
        }
        s.setFilter(processIs("A"))
        #expect(s.isFiltering)
        #expect(await eventually { copies >= 2 })
        #expect(!s.isFiltering)
        #expect(await eventually { s.runningRescans == 0 })
        #expect(copies == 2)  // the rescan stopped
        #expect(!s.rows.isFiltered)
        #expect(s.rows.count == 10_000)
        #expect(rowIDs(s) == expectedIDs(s, nil))
        // Live entries keep coming through unfiltered.
        stream(10_000..<10_300)
        #expect(await settle(s, total: 10_300))
        #expect(s.rows.count == 10_300)
        #expect(s.filterProgress == 1)
    }

    /// on > off while the rescan runs.
    @Test func filterTurnedOffMidRescan() async {
        await expectEverythingBackAfterChangeMidRescan { $0.setFilter(nil) }
    }

    /// A filter whose every condition is invalid matches everything: set mid-rescan, it ends
    /// the rescan like turning the filter off.
    @Test func allInvalidFilterSetMidRescan() async {
        await expectEverythingBackAfterChangeMidRescan {
            $0.setFilter(.all([
                .condition(FilterCondition(field: .message, match: .regex, value: "(")),
                .condition(FilterCondition(field: .pid, match: .is, value: "not a number")),
            ]))
        }
    }

    /// A batch checked against an older filter (here: tagged "everything matches") is judged
    /// by the current filter when drained.
    @Test func staleGenerationRechecked() async {
        let s = makeSession()
        s.start()
        let (oldGeneration, _) = s.filterSlot.current()
        s.setFilter(processIs("A"))
        let batch = entries(0..<9)
        s.queue.push(TaggedBatch(
            entries: batch, matches: Array(repeating: true, count: 9),
            generation: oldGeneration))
        // A current-generation batch is trusted as tagged.
        let (generation, _) = s.filterSlot.current()
        s.queue.push(TaggedBatch(
            entries: [makeEntry(9, process: "A")], matches: [false], generation: generation))
        #expect(await settle(s, total: 10))
        #expect(s.rows.count == 3)
        #expect((0..<s.rows.count).allSatisfy { s.rows[$0].process == "A" })
        #expect(rowIDs(s) == [1, 4, 7])
    }

    // MARK: Filter slower than the input (MVP spec §6.5.1: bounded queue, drop and count)

    /// Process A, or a message regex that never matches `slowMessage` and takes about 1 ms
    /// per entry to say so (`(a+)+$` backtracks on a run of a's ending in "!"). Matches
    /// exactly the process A entries.
    var slowFilter: FilterExpression {
        .any([processIs("A"),
              .condition(FilterCondition(field: .message, match: .regex, value: "(a+)+$"))])
    }
    let slowMessage = String(repeating: "a", count: 12) + "!"

    /// Entries with `slowMessage` (or `message`), the process cycling A, B, C by id.
    func slowEntries(_ range: Range<UInt64>, message: String? = nil) -> [LogEntry] {
        range.map {
            makeEntry($0, message: message ?? slowMessage, process: ["A", "B", "C"][Int($0) % 3])
        }
    }

    /// The filter checks far slower than the transport delivers: raw batches go into the
    /// bounded queue at once, so the excess is dropped and counted and the queue never holds
    /// more than its capacity. Turning the filter off then lets the rest through unchecked.
    @Test func slowFilterDropsAndCountsInsteadOfBuffering() async {
        let capacity = 500
        let s = StreamSession(
            device: mac, transport: transport, budget: MemoryBudget(),
            drainInterval: .milliseconds(5), queueCapacity: capacity)
        s.setFilter(slowFilter)
        s.start()
        for b in UInt64(0)..<40 { transport.yield(slowEntries(b * 100..<b * 100 + 100)) }
        var largest = 0
        #expect(await eventually(timeout: .seconds(3)) {
            largest = max(largest, s.queue.count)
            return s.droppedCount > 0
        })
        #expect(largest <= capacity)
        #expect(s.queue.count <= capacity)

        s.setFilter(nil)  // off: what is queued is drained without waiting for the checker
        #expect(await eventually { s.appendedCount + s.droppedCount == 4_000 })
        #expect(s.queue.count == 0)
        #expect(s.droppedCount >= 4_000 - capacity)
        #expect(s.rows.count == s.store.count)
    }

    /// Pausing while the checker is behind: entries already received still reach the store
    /// and the index once checked (off main), judged by the filter.
    @Test func pauseWhileCheckerBehindKeepsEverything() async {
        let s = makeSession()
        s.setFilter(slowFilter)
        s.start()
        // 14 a's: about 3 ms per B or C entry, several seconds for the batch.
        transport.yield(slowEntries(0..<1_500, message: String(repeating: "a", count: 14) + "!"))
        #expect(await eventually { s.queue.count == 1_500 })  // received, not yet checked
        s.pause()
        #expect(s.state == .paused)
        #expect(s.appendedCount == 0)
        #expect(await eventually(timeout: .seconds(20)) { s.appendedCount == 1_500 })
        #expect(rowIDs(s) == expectedIDs(s, processIs("A")))
        #expect(s.rows.count == 500)
        #expect(s.droppedCount == 0)
        #expect(s.queue.count == 0)
    }

    /// The filter changes while a batch is being checked against the old one: the batch is
    /// judged by the new filter (on > other filter, mid-check).
    @Test func filterChangedWhileCheckerBusy() async {
        let s = makeSession()
        s.setFilter(slowFilter)
        s.start()
        transport.yield(slowEntries(0..<300))
        try? await Task.sleep(for: .milliseconds(20))  // the checker is inside the batch
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 300))
        #expect(rowIDs(s) == expectedIDs(s, processIs("A")))
        #expect(s.rows.count == 100)
        // And off > on again on the same session.
        s.setFilter(nil)
        transport.yield(slowEntries(300..<330))
        #expect(await settle(s, total: 330))
        #expect(s.rows.count == 330)
        s.setFilter(slowFilter)
        transport.yield(slowEntries(330..<360))
        #expect(await settle(s, total: 360, timeout: .seconds(10)))
        #expect(rowIDs(s) == expectedIDs(s, processIs("A")))
        #expect(s.rows.count == 120)
    }

    /// Clear while unchecked batches wait: they are discarded with the rest.
    @Test func clearWhileCheckerBehindDiscardsQueued() async {
        let s = makeSession()
        s.setFilter(slowFilter)
        s.start()
        transport.yield(slowEntries(0..<300))
        try? await Task.sleep(for: .milliseconds(20))
        s.clear()
        #expect(s.queue.count == 0)
        s.setFilter(processIs("A"))
        transport.yield(entries(1_000..<1_030))
        #expect(await eventually { s.appendedCount == 30 })
        #expect(s.store.count == 30)
        #expect(rowIDs(s) == expectedIDs(s, processIs("A")))
        #expect(s.rows.count == 10)
    }

    @Test func disconnectReconnectKeepsFilter() async {
        let s = makeSession()
        s.start()
        s.setFilter(processIs("A"))
        stream(0..<30)
        #expect(await settle(s, total: 30))
        #expect(s.rows.count == 10)

        s.deviceDisappeared()
        #expect(s.state == .disconnected(wasStreaming: true))
        s.deviceReappeared()
        #expect(s.state == .streaming)
        #expect(transport.callCount == 2)
        #expect(s.filter == processIs("A"))
        stream(30..<60)
        #expect(await settle(s, total: 60))
        #expect(s.rows.count == 20)
        #expect(rowIDs(s) == expectedIDs(s, processIs("A")))
    }

    @Test func seenValuesTracked() async {
        let s = makeSession()
        s.start()
        stream(0..<6, batch: 2)
        #expect(await settle(s, total: 6))
        #expect(s.seenValues.values(for: .process) == ["A", "B", "C"])
    }

    /// Catastrophic backtracking: the regex rescan must not hold up the next filter, and it
    /// stops at the next entry once cancelled.
    @Test func pathologicalRegexCancels() async {
        let s = makeSession()
        s.start()
        let message = String(repeating: "a", count: 24) + "!"
        transport.yield((0..<2_000).map {
            makeEntry($0, message: message, process: $0 % 2 == 0 ? "A" : "B")
        })
        #expect(await settle(s, total: 2_000))

        s.setFilter(.condition(FilterCondition(field: .message, match: .regex, value: "(a+)+$")))
        #expect(s.isFiltering)
        try? await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let changed = clock.now
        s.setFilter(processIs("A"))
        #expect(await eventually(timeout: .seconds(2)) { !s.isFiltering })
        #expect(clock.now - changed < .seconds(2))
        #expect(s.filter == processIs("A"))
        #expect(rowIDs(s) == expectedIDs(s, processIs("A")))
        #expect(s.rows.count == 1_000)
        #expect(await eventually(timeout: .seconds(5)) { s.runningRescans == 0 })
    }
}
