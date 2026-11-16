import Foundation
import Testing
import BCFilter
import BCModel
@testable import BCStore
import BCTransport
@testable import BCStreaming

/// Sessions over a finite source (an opened file): they end normally, never drop, and live
/// in the registry beside the discovered devices without being one.
@MainActor
struct FileSessionTests {
    let transport = FakeTransport(isFinite: true)
    let budget = MemoryBudget()

    func makeSession(queueCapacity: Int = 200_000) -> StreamSession {
        StreamSession(
            device: fileA, transport: transport, budget: budget,
            drainInterval: .milliseconds(5), queueCapacity: queueCapacity)
    }

    @Test func endingNormallyFinishesWithEverythingStored() async {
        let s = makeSession()
        #expect(s.isFinite)
        s.start()
        transport.yield(makeEntries(0..<3))
        transport.yield(makeEntries(3..<5))
        transport.finish()
        #expect(await eventually { s.state == .finished })
        #expect(await eventually { s.store.count == 5 })
        #expect(s.droppedCount == 0)
    }

    /// A live stream that ends is still a failure.
    @Test func liveStreamEndingStillFails() async {
        let live = FakeTransport()
        let s = StreamSession(
            device: mac, transport: live, budget: budget, drainInterval: .milliseconds(5))
        #expect(!s.isFinite)
        s.start()
        live.finish()
        #expect(await eventually { s.state == .failed("The log stream ended unexpectedly.") })
    }

    @Test func readErrorFailsWithItsReason() async {
        let s = makeSession()
        s.start()
        transport.yield(makeEntries(0..<2))
        transport.finish(throwing: FakeError())
        #expect(await eventually { s.state == .failed("child exited") })
        #expect(await eventually { s.store.count == 2 })
    }

    /// A small queue and a source far bigger than it: the reader waits for room instead of
    /// dropping.
    @Test func neverDropsWhenTheQueueIsFull() async {
        let s = makeSession(queueCapacity: 100)
        s.start()
        for i in 0..<40 {
            let start = UInt64(i * 50)
            transport.yield(makeEntries(start..<(start + 50)))
        }
        transport.finish()
        #expect(await eventually(timeout: .seconds(5)) { s.store.count == 2_000 })
        #expect(s.droppedCount == 0)
        #expect(s.state == .finished)
        #expect((0..<s.store.count).map { UInt64(s.store[$0].date.timeIntervalSince1970) } == Array(0..<2_000))
    }

    /// Start, Pause and Retry do nothing once the file is read: reading it again would add
    /// every entry twice.
    @Test func finishedIgnoresStartAndPause() async {
        let s = makeSession()
        s.start()
        transport.yield(makeEntries(0..<1))
        transport.finish()
        #expect(await eventually { s.state == .finished && s.store.count == 1 })
        s.start()
        s.pause()
        s.retry()
        #expect(s.state == .finished)
        #expect(transport.callCount == 1)
    }

    /// A filter set while loading and changed after: rows follow, as for live sessions.
    @Test func filterWhileLoadingAndAfter() async {
        let s = makeSession()
        s.setFilter(.condition(FilterCondition(field: .message, match: .is, value: "keep")))
        s.start()
        transport.yield([makeEntry(1, message: "keep"), makeEntry(2, message: "drop")])
        transport.yield([makeEntry(3, message: "keep")])
        transport.finish()
        #expect(await eventually { s.state == .finished && s.store.count == 3 && s.rows.count == 2 })
        s.setFilter(nil)
        #expect(await eventually { s.rows.count == 3 })
    }

    /// A live session at the limit, then a file of older logs: the file keeps everything, the
    /// live session gives way.
    @Test func liveSessionGivesWayToAnOpenedFile() async {
        let one = makeEntry(1).estimatedBytes
        budget.limitBytes = one * 10
        let liveTransport = FakeTransport()
        let live = StreamSession(
            device: mac, transport: liveTransport, budget: budget, drainInterval: .milliseconds(5))
        live.start()
        liveTransport.yield(makeEntries(1_000..<1_010))
        #expect(await eventually { live.store.count == 10 })
        let file = makeSession()
        file.start()
        transport.yield(makeEntries(0..<4))
        transport.finish()
        #expect(await eventually { file.state == .finished && file.store.count == 4 })
        #expect(file.store.removedCount == 0)
        #expect(live.store.count == 6)
    }

    /// Entries beyond the memory limit are evicted oldest first, as for live logs.
    @Test func evictsBeyondTheMemoryLimit() async {
        let one = makeEntry(1).estimatedBytes
        budget.limitBytes = one * 10
        let s = makeSession()
        s.start()
        transport.yield(makeEntries(0..<30))
        transport.finish()
        #expect(await eventually { s.state == .finished && s.store.removedCount == 20 })
        #expect(s.store.count == 10)
    }
}

@MainActor
final class FileSessionRegistryTests {
    let transport = FakeTransport()
    let discovery = FakeDiscovery()
    let budget = MemoryBudget()
    let registry: SessionRegistry
    private let runTask: Task<Void, Never>

    init() {
        registry = SessionRegistry(
            discoveries: [discovery], transports: [transport], budget: budget,
            drainInterval: .milliseconds(5))
        let registry = self.registry
        runTask = Task { await registry.run() }
    }

    isolated deinit { runTask.cancel() }

    @Test func openedFileHasASessionButNoRow() async {
        var created: [LogDevice.ID] = []
        registry.addSessionCreatedHandler { created.append($0.device.id) }
        let file = FakeTransport(isFinite: true)
        let s = registry.openFileSession(device: fileA, transport: file)
        #expect(created == [fileA.id])
        #expect(registry.session(for: fileA.id) === s)
        #expect(!registry.rows.contains { $0.id == fileA.id })
        // Opening it again gives the same session.
        #expect(registry.openFileSession(device: fileA, transport: file) === s)
        #expect(created == [fileA.id])
    }

    /// A discovery update neither disconnects nor drops a file session.
    @Test func discoveryLeavesFileSessionsAlone() async {
        let s = registry.openFileSession(device: fileA, transport: FakeTransport(isFinite: true))
        discovery.push([mac])
        #expect(await eventually { self.registry.rows.contains { $0.id == mac.id } })
        discovery.push([])
        #expect(await eventually { self.registry.rows.isEmpty })
        #expect(registry.session(for: fileA.id) === s)
        #expect(s.state == .idle)
    }

    /// Closing the window releases the session and its share of the memory budget.
    @Test func closingReleasesTheSession() async {
        let file = FakeTransport(isFinite: true)
        weak var weakSession: StreamSession?
        do {
            let s = registry.openFileSession(device: fileA, transport: file)
            weakSession = s
            s.start()
            file.yield(makeEntries(0..<3))
            file.finish()
            #expect(await eventually { s.state == .finished && s.store.count == 3 })
            #expect(budget.registeredCount == 1)
        }
        registry.closeFileSession(id: fileA.id)
        #expect(registry.session(for: fileA.id) == nil)
        #expect(await eventually { weakSession == nil })
        #expect(budget.registeredCount == 0)
    }

    /// The device's filter reaches the file session through the workspace, as for devices,
    /// and stops once it is closed.
    @Test func workspaceFilterReachesTheFileSession() async {
        let library = FilterLibrary(storage: MemoryLibraryStorage())
        let workspace = FilterWorkspace(library: library, persistence: MemoryDeviceFilters())
        let condition = FilterExpression.condition(FilterCondition(field: .process, match: .is, value: "a"))
        workspace.setExpression(condition, for: fileA.id)
        connect(registry: registry, workspace: workspace)
        let s = registry.openFileSession(device: fileA, transport: FakeTransport(isFinite: true))
        #expect(s.filter == condition)
        workspace.setExpression(nil, for: fileA.id)
        #expect(s.filter == nil)
    }
}
