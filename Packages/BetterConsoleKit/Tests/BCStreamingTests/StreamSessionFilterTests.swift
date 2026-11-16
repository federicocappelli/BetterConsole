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

    /// Process A, or a message regex that never matches `slowMessage` and takes far longer
    /// per entry than a plain comparison to say so (`(a+)+$` backtracks on a run of a's ending
    /// in "!"; how long depends on the machine, so tests that need the checker to be behind
    /// hold it with `checkerGate` instead). Matches exactly the process A entries.
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
    /// and the index once checked (off main), judged by the filter. The checker is held inside
    /// the batch by its test gate, so it is behind for as long as the test needs.
    @Test func pauseWhileCheckerBehindKeepsEverything() async {
        let s = makeSession()
        s.checkerGate.close()
        s.setFilter(processIs("A"))
        s.start()
        transport.yield(entries(0..<1_500))
        // Received, and the checker is stuck on the batch's first entry.
        #expect(await eventually { s.queue.count == 1_500 && s.checkerGate.isHolding })
        s.pause()
        #expect(s.state == .paused)
        #expect(s.appendedCount == 0)
        s.checkerGate.open()
        #expect(await eventually { s.appendedCount == 1_500 })
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

    /// Clear while unchecked batches wait: they are discarded with the rest. The checker is
    /// held inside the batch by its test gate until after the clear.
    @Test func clearWhileCheckerBehindDiscardsQueued() async {
        let s = makeSession()
        s.checkerGate.close()
        s.setFilter(processIs("B"))
        s.start()
        let appended = s.appendedCount
        transport.yield(entries(0..<300))
        #expect(await eventually { s.queue.count == 300 && s.checkerGate.isHolding })
        s.clear()
        #expect(s.queue.count == 0)
        s.setFilter(processIs("A"))
        s.checkerGate.open()
        transport.yield(entries(1_000..<1_030))
        #expect(await eventually { s.appendedCount - appended == 30 })
        #expect(s.appendedCount - appended == 30)  // none of the cleared 300
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

    // MARK: Match count for the editor preview (ES §8.5)

    @Test func countMatchesCountsStore() async {
        let s = makeSession()
        s.maxRescanChunk = 700  // several chunks
        s.start()
        stream(0..<5_000, batch: 500)
        #expect(await settle(s, total: 5_000))
        var copies = 0
        s.afterRescanCopy = { copies += 1 }
        let count = await s.countMatches(processIs("B"))
        #expect(count == MatchCount(matched: expectedIDs(s, processIs("B")).count, total: 5_000))
        #expect(count?.matched == 1_667)
        #expect(copies >= 8)  // chunked like the rescan
        // A filter with a regex (checked per entry) counts the same.
        let regex = FilterExpression.condition(
            FilterCondition(field: .process, match: .regex, value: "A|C"))
        #expect(await s.countMatches(regex)
            == MatchCount(matched: expectedIDs(s, regex).count, total: 5_000))
    }

    /// A recount starts at the chunk size the last count ended with, not back at the
    /// largest chunk (copies are made to look slow, so each one halves the size).
    @Test func recountKeepsTheAdaptedChunkSize() async {
        let s = makeSession()
        s.maxRescanChunk = 4_000
        s.start()
        stream(0..<10_000, batch: 1_000)
        #expect(await settle(s, total: 10_000))
        s.copyDurationOverride = .milliseconds(10)
        var copies = 0
        s.afterRescanCopy = { copies += 1 }
        // 4,000, 2,000, 1,000, 500, then 500s: 9 copies.
        #expect(await s.countMatches(processIs("A"))?.matched == 3_334)
        #expect(copies == 9)
        copies = 0
        // 500 from the start: 20 copies.
        #expect(await s.countMatches(processIs("B"))?.matched == 3_333)
        #expect(copies == 20)
        // Quick copies grow it again, as in the rescan.
        s.copyDurationOverride = .zero
        copies = 0
        #expect(await s.countMatches(processIs("C"))?.matched == 3_333)
        #expect(copies == 5)  // 500, 1,000, 2,000, 4,000, then the last 2,500
    }

    @Test func countWithNoFilterIsTotal() async {
        let s = makeSession()
        #expect(await s.countMatches(nil) == MatchCount(matched: 0, total: 0))
        #expect(await s.countMatches(processIs("A")) == MatchCount(matched: 0, total: 0))
        s.start()
        stream(0..<1_234)
        #expect(await settle(s, total: 1_234))
        #expect(await s.countMatches(nil) == MatchCount(matched: 1_234, total: 1_234))
        // Every condition invalid: matches everything.
        let invalid = FilterExpression.condition(
            FilterCondition(field: .message, match: .regex, value: "("))
        #expect(await s.countMatches(invalid) == MatchCount(matched: 1_234, total: 1_234))
    }

    /// The count leaves the session's filter, rows and revision alone, with the session
    /// filtered (by another filter) and unfiltered.
    @Test func countDoesNotChangeRows() async {
        let s = makeSession()
        s.maxRescanChunk = 500
        s.start()
        stream(0..<3_000, batch: 500)
        #expect(await settle(s, total: 3_000))
        s.setFilter(processIs("B"))
        #expect(await settle(s, total: 3_000))
        let ids = rowIDs(s)
        let revision = s.revision
        let resets = s.rows.resetCount
        #expect(await s.countMatches(processIs("A"))?.matched == 1_000)
        #expect(s.filter == processIs("B"))
        #expect(rowIDs(s) == ids)
        #expect(s.revision == revision)
        #expect(s.rows.resetCount == resets)
        #expect(!s.isFiltering)
        #expect(s.filterProgress == 1)

        s.setFilter(nil)
        #expect(await s.countMatches(processIs("A"))?.matched == 1_000)
        #expect(s.filter == nil)
        #expect(!s.rows.isFiltered)
        #expect(s.rows.count == 3_000)
    }

    /// Catastrophic backtracking: cancelling the counting task returns nil within 1 s.
    @Test func countCancelsPromptly() async {
        let s = makeSession()
        s.start()
        let message = String(repeating: "a", count: 24) + "!"
        transport.yield((0..<2_000).map { makeEntry($0, message: message, process: "A") })
        #expect(await settle(s, total: 2_000))
        let regex = FilterExpression.condition(
            FilterCondition(field: .message, match: .regex, value: "(a+)+$"))
        let counting = Task { await s.countMatches(regex) }
        try? await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let cancelled = clock.now
        counting.cancel()
        let result = await counting.value
        #expect(clock.now - cancelled < .seconds(1))
        #expect(result == nil)
    }

    /// A count cancelled before it starts returns nil, even with no filter.
    @Test func countAlreadyCancelledIsNil() async {
        let s = makeSession()
        s.start()
        stream(0..<100)
        #expect(await settle(s, total: 100))
        let counting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await s.countMatches(processIs("A"))
        }
        #expect(await counting.value == nil)
    }

    /// Eviction mid-count: entries evicted before their chunk is copied are not counted (in
    /// matched or total); chunks already copied stay counted.
    @Test func countEvictionDuringCount() async {
        let budget = MemoryBudget()
        let s = makeSession(budget: budget)
        s.maxRescanChunk = 1_000
        s.start()
        stream(0..<10_000, batch: 1_000)
        #expect(await settle(s, total: 10_000))
        let perEntry = s.store.estimatedBytes / s.store.count
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            guard copies == 3 else { return }  // [7000, 10000) copied; keep [6500, 10000)
            budget.limitBytes = perEntry * 3_500
        }
        let count = await s.countMatches(processIs("A"))
        #expect(copies == 4)  // the last chunk is the 500 entries left above the evicted part
        #expect(s.store.removedCount == 6_500)
        #expect(count == MatchCount(matched: expectedIDs(s, processIs("A")).count, total: 3_500))
        #expect(s.filter == nil)
    }

    /// Clear mid-count: the count covers only what was copied before the clear.
    @Test func countClearedMidCount() async {
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
        let count = await s.countMatches(processIs("A"))
        #expect(copies == 2)
        #expect(count == MatchCount(
            matched: (8_000..<10_000).filter { $0 % 3 == 0 }.count, total: 2_000))
    }

    /// Entries arriving during the count are not included: it counts what was stored when it
    /// started (ES §8.5: the count does not follow new messages).
    @Test func countIgnoresEntriesArrivingDuringCount() async {
        let s = makeSession()
        s.maxRescanChunk = 1_000
        s.start()
        stream(0..<5_000, batch: 1_000)
        #expect(await settle(s, total: 5_000))
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            if copies == 1 { self.stream(5_000..<6_000, batch: 1_000) }
        }
        let count = await s.countMatches(processIs("A"))
        #expect(count == MatchCount(
            matched: (0..<5_000).filter { $0 % 3 == 0 }.count, total: 5_000))
        #expect(await settle(s, total: 6_000))
        #expect(await s.countMatches(processIs("A"))
            == MatchCount(matched: 2_000, total: 6_000))
    }

    /// A count runs alongside a rescan of a different filter; neither disturbs the other.
    @Test func countDuringRescan() async {
        let s = makeSession()
        s.maxRescanChunk = 1_000
        s.start()
        stream(0..<20_000, batch: 1_000)
        #expect(await settle(s, total: 20_000))
        s.setFilter(processIs("B"))
        #expect(s.isFiltering)
        let count = await s.countMatches(processIs("A"))
        #expect(count == MatchCount(matched: expectedIDs(s, processIs("A")).count, total: 20_000))
        #expect(await settle(s, total: 20_000))
        #expect(rowIDs(s) == expectedIDs(s, processIs("B")))
    }
}
