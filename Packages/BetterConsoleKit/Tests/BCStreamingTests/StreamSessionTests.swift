import Testing
import BCModel
import BCStore
import BCTransport
@testable import BCStreaming

@MainActor
struct StreamSessionTests {
    let transport = FakeTransport()
    let budget = MemoryBudget()

    func makeSession(queueCapacity: Int = 200_000) -> StreamSession {
        StreamSession(
            device: mac, transport: transport, budget: budget,
            drainInterval: .milliseconds(5), queueCapacity: queueCapacity)
    }

    func ids(_ s: StreamSession) -> [UInt64] { (0..<s.store.count).map { s.store[$0].id } }
    /// The id the fake transport gave each stored entry (`makeEntry` encodes it in the date);
    /// `id` itself is re-stamped by the session.
    func sourceIDs(_ s: StreamSession) -> [UInt64] {
        (0..<s.store.count).map { UInt64(s.store[$0].date.timeIntervalSince1970) }
    }

    @Test func startStreamsIntoStore() async {
        let s = makeSession()
        #expect(s.state == .idle)
        s.start()
        #expect(s.state == .streaming)
        #expect(transport.callCount == 1)
        transport.yield(makeEntries(0..<3))
        transport.yield(makeEntries(3..<5))
        #expect(await eventually { s.store.count == 5 })
        #expect(ids(s) == [1, 2, 3, 4, 5])  // re-stamped by the session, from 1
        #expect(s.revision > 0)
        s.start()  // no-op while streaming
        #expect(transport.callCount == 1)
    }

    @Test func revisionOnlyBumpsWhenStoreChanges() async {
        let s = makeSession()
        s.start()
        transport.yield(makeEntries(0..<1))
        #expect(await eventually { s.store.count == 1 })
        let r = s.revision
        try? await Task.sleep(for: .milliseconds(30))  // several empty drains
        #expect(s.revision == r)
    }

    @Test func pauseStopsAndKeepsEntries() async {
        let s = makeSession()
        s.start()
        transport.yield(makeEntries(0..<3))
        #expect(await eventually { s.store.count == 3 })
        s.pause()
        #expect(s.state == .paused)
        #expect(await eventually { transport.isTerminated(0) })
        #expect(transport.wasCancelled(0))
        #expect(s.store.count == 3)
        #expect(s.state == .paused)  // session-initiated cancellation is not a failure
    }

    @Test func startAfterPauseAppends() async {
        let s = makeSession()
        s.start()
        transport.yield(makeEntries(0..<2))
        #expect(await eventually { s.store.count == 2 })
        s.pause()
        s.start()
        #expect(s.state == .streaming)
        #expect(transport.callCount == 2)
        transport.yield(makeEntries(2..<4))
        #expect(await eventually { s.store.count == 4 })
        #expect(ids(s) == [1, 2, 3, 4])
    }

    /// Every stream's decoder numbers its entries from 1; the session's ids keep increasing
    /// across pause/start and clear.
    @Test func idsIncreaseAcrossStreamsAndClear() async {
        let s = makeSession()
        s.start()
        transport.yield(makeEntries(1..<4))
        #expect(await eventually { s.store.count == 3 })
        s.pause()
        s.start()
        transport.yield(makeEntries(1..<4))  // a new stream restarts at 1
        #expect(await eventually { s.store.count == 6 })
        #expect(ids(s) == [1, 2, 3, 4, 5, 6])
        let fields = (0..<6).map { s.store[$0].date }
        #expect(fields == makeEntries(1..<4).map(\.date) + makeEntries(1..<4).map(\.date))

        s.clear()
        transport.yield(makeEntries(1..<3))
        #expect(await eventually { s.store.count == 2 })
        #expect(ids(s) == [7, 8])
    }

    @Test func pauseStartPauseCycle() async {
        let s = makeSession()
        for round in 0..<3 {
            s.start()
            let base = UInt64(round * 10)
            transport.yield(makeEntries(base..<base + 2))
            #expect(await eventually { s.store.count == (round + 1) * 2 })
            s.pause()
            #expect(await eventually { transport.isTerminated(round) })
        }
        #expect(transport.callCount == 3)
        #expect(transport.activeCount == 0)
        #expect(s.state == .paused)
    }

    @Test func clearKeepsStreamingAndResetsDropped() async {
        let s = makeSession(queueCapacity: 10)
        s.start()
        transport.yield(makeEntries(0..<25))
        #expect(await eventually { s.droppedCount == 15 })
        let r = s.revision
        s.clear()
        #expect(s.state == .streaming)
        #expect(s.store.count == 0)
        #expect(s.droppedCount == 0)
        #expect(s.revision > r)
        transport.yield(makeEntries(100..<102))
        #expect(await eventually { s.store.count == 2 })
        #expect(sourceIDs(s) == [100, 101])
        #expect(ids(s) == [11, 12])  // 10 stored before the clear; ids are not reset
    }

    @Test func clearWhilePausedKeepsPaused() async {
        let s = makeSession()
        s.start()
        transport.yield(makeEntries(0..<2))
        #expect(await eventually { s.store.count == 2 })
        s.pause()
        s.clear()
        #expect(s.state == .paused)
        #expect(s.store.count == 0)
        s.start()
        transport.yield(makeEntries(5..<6))
        #expect(await eventually { s.store.count == 1 })
        #expect(sourceIDs(s) == [5])
        #expect(ids(s) == [3])
    }

    @Test func droppedCountAccumulates() async {
        let s = makeSession(queueCapacity: 10)
        s.start()
        transport.yield(makeEntries(0..<25))
        #expect(await eventually { s.droppedCount == 15 && s.store.count == 10 })
        transport.yield(makeEntries(25..<50))
        #expect(await eventually { s.droppedCount == 30 && s.store.count == 20 })
    }

    @Test func childDeathGoesFailedThenRetry() async {
        let s = makeSession()
        s.start()
        transport.yield(makeEntries(0..<2))
        transport.finish(throwing: FakeError())
        #expect(await eventually { s.state == .failed("child exited") })
        #expect(s.store.count == 2)  // entries received before the failure are kept
        s.retry()
        #expect(s.state == .streaming)
        #expect(transport.callCount == 2)
        transport.yield(makeEntries(2..<3))
        #expect(await eventually { s.store.count == 3 })
    }

    @Test func transportErrorReadsAsSentenceInFailedState() async {
        let s = makeSession()
        s.start()
        transport.finish(throwing: TransportError.processExited(status: 15))
        #expect(await eventually { s.state == .failed("The log process exited unexpectedly (status 15).") })
    }

    @Test func streamEndingWithoutErrorIsAFailure() async {
        let s = makeSession()
        s.start()
        transport.finish()
        #expect(await eventually {
            if case .failed = s.state { true } else { false }
        })
        s.start()  // start from failed works like retry
        #expect(s.state == .streaming)
        #expect(transport.callCount == 2)
    }

    @Test func preventsAppNapOnlyWhileStreaming() async {
        // Under App Nap (window hidden or covered) decoding fell from ~20k to ~7k msgs/s.
        let s = makeSession()
        #expect(!s.isPreventingAppNap)
        s.start()
        #expect(s.isPreventingAppNap)
        s.pause()
        #expect(!s.isPreventingAppNap)
        s.start()
        #expect(s.isPreventingAppNap)
        transport.finish(throwing: FakeError(), index: 1)
        #expect(await eventually { if case .failed = s.state { true } else { false } })
        #expect(!s.isPreventingAppNap)
        s.retry()
        #expect(s.isPreventingAppNap)
        s.deviceDisappeared()
        #expect(!s.isPreventingAppNap)
    }

    @Test func noTransportFails() {
        let s = StreamSession(device: mac, transport: nil, budget: budget)
        s.start()
        #expect(s.state == .failed("No transport for this device"))
    }

    @Test func budgetEnforcedOnDrain() async {
        let per = makeEntry(0).estimatedBytes
        budget.limitBytes = per * 4
        let s = makeSession()
        s.start()
        transport.yield(makeEntries(0..<10))
        #expect(await eventually { s.store.count > 0 && s.store.count <= 4 })
        #expect(s.store.estimatedBytes <= per * 4)
        #expect(sourceIDs(s).last == 9)
        #expect(s.store[s.store.count - 1].id == 10)
    }

    @Test func releasedSessionStopsItsStream() async {
        var s: StreamSession? = makeSession()
        weak let weakSession = s
        s?.start()
        transport.yield(makeEntries(0..<2))
        #expect(await eventually { s?.store.count == 2 })
        s = nil
        #expect(await eventually { weakSession == nil })
        #expect(await eventually { transport.isTerminated(0) })
    }
}
