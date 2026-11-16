import Testing
import BCModel
import BCStore
import BCTransport
@testable import BCStreaming

@MainActor
final class SessionRegistryTests {
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

    func row(_ id: String) -> SessionRegistry.Row? { registry.rows.first { $0.device.id == id } }

    /// Pushes `devices` and waits until the registry has applied the update.
    func push(_ devices: [LogDevice]) async {
        discovery.push(devices + [marker()])
        let id = markerID
        #expect(await eventually { self.registry.rows.contains { $0.device.id == id } })
    }

    // A unique always-present device per push, used as a barrier: once it shows up in `rows`,
    // every earlier update from the same discovery has been applied.
    private var markerSeq = 0
    private var markerID = ""
    private func marker() -> LogDevice {
        markerSeq += 1
        markerID = "zz-marker-\(markerSeq)"
        return LogDevice(id: markerID, name: "zz \(markerSeq)", kind: .simulator)
    }

    /// Starts streaming simA and waits for one entry in its store.
    func streamSimA() async -> StreamSession {
        await push([mac, simA])
        let s = registry.session(for: simA.id)!
        s.start()
        transport.yield(makeEntries(0..<1))
        #expect(await eventually { s.store.count == 1 })
        return s
    }

    @Test func rowsMergeDiscoveries() async {
        let first = FakeDiscovery(), other = FakeDiscovery()
        let r = SessionRegistry(
            discoveries: [first, other], transports: [transport], budget: MemoryBudget())
        let task = Task { await r.run() }
        defer { task.cancel() }
        first.push([simB, mac, phoneB])
        other.push([phoneA, simA, mac])
        #expect(await eventually { r.rows.count == 5 })
        #expect(r.rows.map(\.device.id) == ["local", "phone-a", "phone-b", "sim-a", "sim-b"])
        #expect(r.rows.allSatisfy { $0.isAvailable })
        // The latest list per discovery wins.
        other.push([])
        #expect(await eventually { r.rows.count == 3 })
        #expect(r.rows.map(\.device.id) == ["local", "phone-b", "sim-b"])
    }

    @Test func sessionsAreCreatedOnDiscoveryAndKeyedByID() async {
        await push([mac, simA])
        #expect(registry.session(for: "unknown") == nil)
        let s = registry.session(for: simA.id)
        #expect(s != nil)
        #expect(registry.session(for: simA.id) === s)
        #expect(s?.state == .idle)
        #expect(transport.callCount == 0)
    }

    @Test func registryHookCalledOnCreate() async {
        var seen: [(id: LogDevice.ID, state: StreamSession.State)] = []
        registry.onSessionCreated = { seen.append(($0.device.id, $0.state)) }
        await push([mac, simA])
        await push([mac, simA, simB])  // only simB is new
        let ids = seen.map(\.id).filter { !$0.hasPrefix("zz-marker") }
        #expect(ids.sorted() == ["local", "sim-a", "sim-b"])
        #expect(seen.allSatisfy { $0.state == .idle })
        #expect(registry.session(for: simB.id) != nil)
    }

    /// `session(for:)` never creates anything: every discovered device already has a session
    /// after the update, and lookups of unknown ids leave no trace.
    @Test func sessionLookupIsPure() async {
        await push([mac, simA, simB])
        let present = registry.rows.map(\.device.id)
        #expect(present.count == 4)  // mac, simA, simB, marker
        // Every discovered device has a session, observed only through the internal map.
        #expect(Set(registry.sessionIDs) == Set(present))
        for id in present { #expect(registry.session(for: id)?.device.id == id) }
        #expect(registry.session(for: "unknown") == nil)
        #expect(registry.session(for: phoneA.id) == nil)
        #expect(Set(registry.sessionIDs) == Set(present))
        #expect(transport.callCount == 0)
    }

    @Test func picksFirstSupportingTransport() async {
        let macOnly = FakeTransport(supported: ["local"])
        let d = FakeDiscovery()
        let r = SessionRegistry(
            discoveries: [d], transports: [macOnly, transport], budget: MemoryBudget())
        let task = Task { await r.run() }
        defer { task.cancel() }
        d.push([mac, simA])
        #expect(await eventually { r.rows.count == 2 })
        r.session(for: simA.id)!.start()
        r.session(for: mac.id)!.start()
        #expect(macOnly.callCount == 1)
        #expect(transport.callCount == 1)
    }

    @Test func noTransportFailsOnStart() async {
        let d = FakeDiscovery()
        let r = SessionRegistry(
            discoveries: [d], transports: [FakeTransport(supported: [])],
            budget: MemoryBudget())
        let task = Task { await r.run() }
        defer { task.cancel() }
        d.push([simA])
        #expect(await eventually { r.rows.count == 1 })
        let s = r.session(for: simA.id)!
        s.start()
        #expect(s.state == .failed("No transport for this device"))
    }

    @Test func disappearWhileStreamingKeepsRowGreyed() async {
        let s = await streamSimA()
        await push([mac])
        #expect(s.state == .disconnected(wasStreaming: true))
        #expect(row(simA.id)?.isAvailable == false)
        #expect(await eventually { self.transport.isTerminated(0) })
        #expect(transport.wasCancelled(0))
        #expect(s.store.count == 1)
        #expect(registry.session(for: simA.id) === s)
    }

    @Test func reappearAutoResumesOnce() async {
        let s = await streamSimA()
        await push([mac])
        await push([mac, simA])
        #expect(s.state == .streaming)
        #expect(row(simA.id)?.isAvailable == true)
        await push([simA, mac])  // duplicate reappear
        #expect(transport.callCount == 2)
        #expect(transport.activeCount == 1)
        transport.yield(makeEntries(1..<2))
        #expect(await eventually { s.store.count == 2 })  // same store, appended
    }

    @Test func flappingDoesNotDuplicate() async {
        let s = await streamSimA()
        // Four updates queued before the registry gets to run any of them.
        discovery.push([mac])
        discovery.push([mac, simA])
        discovery.push([mac])
        discovery.push([mac, simA])
        await push([mac, simA])
        #expect(s.state == .streaming)
        #expect(transport.callCount == 3)
        #expect(await eventually {
            self.transport.isTerminated(0) && self.transport.isTerminated(1)
        })
        #expect(!transport.isTerminated(2))
        #expect(transport.activeCount == 1)
        transport.yield(makeEntries(1..<3))
        #expect(await eventually { s.store.count == 3 })
    }

    @Test func flappingWhilePausedNeverStarts() async {
        let s = await streamSimA()
        s.pause()
        discovery.push([mac])
        discovery.push([mac, simA])
        discovery.push([mac])
        discovery.push([mac, simA])
        await push([mac, simA])
        #expect(s.state == .paused)
        #expect(transport.callCount == 1)
    }

    @Test func pausedStaysPausedOnReturn() async {
        let s = await streamSimA()
        s.pause()
        await push([mac])
        #expect(s.state == .disconnected(wasStreaming: false))
        await push([mac, simA])
        #expect(s.state == .paused)
        #expect(transport.callCount == 1)
        #expect(s.store.count == 1)
    }

    @Test func pauseWhileDisconnectedPreventsAutoResume() async {
        let s = await streamSimA()
        await push([mac])
        s.pause()
        #expect(s.state == .disconnected(wasStreaming: false))
        await push([mac, simA])
        #expect(s.state == .paused)
        #expect(transport.callCount == 1)
    }

    @Test func startWhileDisconnectedResumesOnReturn() async {
        let s = await streamSimA()
        s.pause()
        await push([mac])
        s.start()
        #expect(s.state == .disconnected(wasStreaming: true))
        #expect(transport.callCount == 1)  // device absent: nothing launched yet
        await push([mac, simA])
        #expect(s.state == .streaming)
        #expect(transport.callCount == 2)
    }

    @Test func emptySessionRowRemovedOnDisappear() async {
        await push([mac, simA, simB])
        let idle = registry.session(for: simA.id)!
        let streamingEmpty = registry.session(for: simB.id)!
        streamingEmpty.start()
        #expect(idle.store.count == 0)
        await push([mac])
        // Both rows go (nothing to browse); the idle session is dropped, the streaming one is
        // kept so it can auto-resume.
        #expect(row(simA.id) == nil)
        #expect(row(simB.id) == nil)
        #expect(registry.session(for: simA.id) == nil)
        #expect(registry.session(for: simB.id) === streamingEmpty)
        #expect(streamingEmpty.state == .disconnected(wasStreaming: true))
        #expect(await eventually { self.transport.isTerminated(0) })
        // Coming back: a fresh idle session for A, auto-resume for B.
        await push([mac, simA, simB])
        #expect(registry.session(for: simA.id)?.state == .idle)
        #expect(streamingEmpty.state == .streaming)
        #expect(transport.callCount == 2)
        #expect(row(simB.id)?.isAvailable == true)
        transport.yield(makeEntries(0..<1))
        #expect(await eventually { streamingEmpty.store.count == 1 })
    }

    @Test func evictionByAnotherSessionBumpsRevisionAndHidesEmptiedRow() async {
        let per = makeEntry(0).estimatedBytes
        let b = await streamSimA()  // simA: entry 0 (oldest)
        transport.yield(makeEntries(1..<3))
        #expect(await eventually { b.store.count == 3 })
        b.pause()
        await push([mac])
        #expect(b.state == .disconnected(wasStreaming: false))
        #expect(row(simA.id)?.isAvailable == false)

        budget.limitBytes = per * 5
        let a = registry.session(for: mac.id)!
        a.start()
        let bRevision = b.revision
        transport.yield(makeEntries(100..<102))  // total 5: at the limit, nothing evicted
        #expect(await eventually { a.store.count == 2 })
        #expect(b.store.count == 3)
        #expect(b.revision == bRevision)
        transport.yield(makeEntries(102..<103))  // evicts B's oldest entry
        #expect(await eventually { b.store.count == 2 })
        #expect(b.revision > bRevision)
        let afterFirst = b.revision
        transport.yield(makeEntries(103..<105))  // evicts B to empty
        #expect(await eventually { b.store.count == 0 })
        #expect(b.revision > afterFirst)
        #expect(row(simA.id) == nil)
        #expect(a.store.count == 5)
    }

    @Test func clearWhileDisconnectedHidesRow() async {
        let s = await streamSimA()
        await push([mac])
        #expect(row(simA.id)?.isAvailable == false)
        s.clear()
        #expect(row(simA.id) == nil)
        #expect(s.state == .disconnected(wasStreaming: true))
        await push([mac, simA])
        #expect(row(simA.id)?.isAvailable == true)
        #expect(s.state == .streaming)
        #expect(transport.callCount == 2)
    }

    @Test func selectionFallsBackToMacWhenClearedWhileDisconnected() async {
        let s = await streamSimA()
        #expect(registry.validSelection(simA.id) == simA.id)
        await push([mac])
        // Greyed row with logs: still selectable.
        #expect(registry.validSelection(simA.id) == simA.id)
        s.clear()
        // The session still exists (it will auto-resume) but its row is gone.
        #expect(registry.session(for: simA.id) === s)
        #expect(registry.validSelection(simA.id) == mac.id)
        await push([mac, simA])
        #expect(registry.validSelection(simA.id) == simA.id)
    }

    @Test func selectionFallsBackToMacForStreamingSessionWithoutLogs() async {
        await push([mac, simB])
        let s = registry.session(for: simB.id)!
        s.start()
        #expect(registry.validSelection(simB.id) == simB.id)
        await push([mac])
        #expect(registry.session(for: simB.id) === s)
        #expect(registry.validSelection(simB.id) == mac.id)
        #expect(registry.validSelection(nil) == nil)
        #expect(registry.validSelection(mac.id) == mac.id)
    }

    @Test func childDeathWhilePresentFailsAndRetries() async {
        let s = await streamSimA()
        transport.finish(throwing: FakeError())
        #expect(await eventually { s.state == .failed("child exited") })
        await push([mac, simA])  // device still present: stays failed
        #expect(s.state == .failed("child exited"))
        #expect(transport.callCount == 1)
        s.retry()
        #expect(s.state == .streaming)
        #expect(transport.callCount == 2)
    }

    @Test func errorThenDisappearBecomesDisconnected() async {
        let s = await streamSimA()
        transport.finish(throwing: FakeError())
        #expect(await eventually { s.state == .failed("child exited") })
        await push([mac])
        #expect(s.state == .disconnected(wasStreaming: true))
        await push([mac, simA])
        #expect(s.state == .streaming)
        #expect(transport.callCount == 2)
    }

    @Test func staleFailureThenDisappearDoesNotAutoResume() async {
        let s = await streamSimA()
        transport.finish(throwing: FakeError())
        #expect(await eventually { s.state == .failed("child exited") })
        await push([mac, simA])  // device seen present after the failure
        await push([mac])
        #expect(s.state == .disconnected(wasStreaming: false))
        await push([mac, simA])
        #expect(s.state == .paused)
        #expect(transport.callCount == 1)
    }
}
