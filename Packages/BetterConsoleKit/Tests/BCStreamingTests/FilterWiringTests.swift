import Testing
import BCFilter
import BCModel
import BCStore
import BCTransport
@testable import BCStreaming

/// `connect(registry:workspace:)` end to end: a real `SessionRegistry` fed by `FakeDiscovery`,
/// a real `FilterWorkspace` and `FilterLibrary` over in-memory storage. A relaunch is a new
/// library, workspace and registry over the same storage.
@MainActor
final class FilterWiringTests {
    let libraryStorage = MemoryLibraryStorage()
    let deviceFilters = MemoryDeviceFilters()

    /// One launch of the app's filter plumbing.
    @MainActor final class Launch {
        let library: FilterLibrary
        let workspace: FilterWorkspace
        let discovery = FakeDiscovery()
        let transport = FakeTransport()
        let registry: SessionRegistry
        private let runTask: Task<Void, Never>
        private var markerSeq = 0

        init(libraryStorage: MemoryLibraryStorage, deviceFilters: MemoryDeviceFilters) {
            library = FilterLibrary(storage: libraryStorage)
            workspace = FilterWorkspace(library: library, persistence: deviceFilters)
            registry = SessionRegistry(
                discoveries: [discovery], transports: [transport], budget: MemoryBudget(),
                drainInterval: .milliseconds(5))
            connect(registry: registry, workspace: workspace)
            let registry = self.registry
            runTask = Task { await registry.run() }
        }

        isolated deinit { runTask.cancel() }

        /// Pushes `devices` and waits until the registry has applied the update (a unique
        /// marker device is the barrier).
        func push(_ devices: [LogDevice]) async {
            markerSeq += 1
            let marker = LogDevice(id: "zz-marker-\(markerSeq)", name: "zz", kind: .simulator)
            discovery.push(devices + [marker])
            #expect(await eventually { self.registry.rows.contains { $0.id == marker.id } })
        }

        func session(_ device: LogDevice) -> StreamSession? { registry.session(for: device.id) }
    }

    func launch() -> Launch { Launch(libraryStorage: libraryStorage, deviceFilters: deviceFilters) }

    func processIs(_ value: String) -> FilterExpression {
        .condition(FilterCondition(field: .process, match: .is, value: value))
    }

    @Test func liveSessionFollowsWorkspaceEdits() async {
        let app = launch()
        await app.push([mac])
        let s = app.session(mac)!
        #expect(s.filter == nil)
        app.workspace.setExpression(processIs("A"), for: mac.id)
        #expect(s.filter == processIs("A"))
        let f = app.workspace.saveAs(name: "F", for: mac.id)
        app.workspace.select(nil, for: mac.id)
        #expect(s.filter == nil)
        app.workspace.select(f.id, for: mac.id)
        #expect(s.filter == processIs("A"))
    }

    /// Relaunch: the saved filter of one device and the unsaved edit of another come back on
    /// their new sessions.
    @Test func filtersRestoredOnRelaunch() async {
        var first: Launch? = launch()
        let f = first!.library.add(name: "F", expression: processIs("A"))
        first!.workspace.select(f.id, for: mac.id)
        first!.workspace.setExpression(processIs("B"), for: simA.id)
        first = nil

        let app = launch()
        await app.push([mac, simA])
        #expect(app.session(mac)?.filter == processIs("A"))
        #expect(app.session(simA)?.filter == processIs("B"))
        #expect(app.workspace.displayName(for: mac.id) == "F")
        #expect(app.workspace.state(for: simA.id).isEdited)
    }

    /// An idle session with no logs is dropped when its device goes; the device comes back
    /// as a new session that starts with its filter.
    @Test func returningDeviceGetsItsFilterOnANewSession() async {
        let app = launch()
        let f = app.library.add(name: "F", expression: processIs("A"))
        app.workspace.select(f.id, for: simA.id)
        await app.push([mac, simA])
        let old = app.session(simA)!
        #expect(old.filter == processIs("A"))
        await app.push([mac])
        #expect(app.session(simA) == nil)
        await app.push([mac, simA])
        let new = app.session(simA)!
        #expect(new !== old)
        #expect(new.filter == processIs("A"))
    }

    /// While the device is away its filter is saved from another device: the device was not
    /// edited, so it comes back with the new version.
    @Test func filterResavedWhileDeviceAway() async {
        let app = launch()
        let f = app.library.add(name: "F", expression: processIs("A"))
        app.workspace.select(f.id, for: simA.id)
        app.workspace.select(f.id, for: mac.id)
        await app.push([mac, simA])
        await app.push([mac])
        #expect(app.session(simA) == nil)

        app.workspace.setExpression(processIs("C"), for: mac.id)
        app.workspace.save(for: mac.id)
        #expect(app.session(mac)?.filter == processIs("C"))

        await app.push([mac, simA])
        #expect(app.session(simA)?.filter == processIs("C"))
        #expect(app.workspace.state(for: simA.id)
            == DeviceFilterState(basedOn: f.id, expression: processIs("C"), isEdited: false))
    }

    /// Deleted while the device is away: it comes back Untitled with the same bubbles.
    @Test func filterDeletedWhileDeviceAway() async {
        let app = launch()
        let f = app.library.add(name: "F", expression: processIs("A"))
        app.workspace.select(f.id, for: simA.id)
        await app.push([mac, simA])
        await app.push([mac])
        #expect(app.session(simA) == nil)

        app.workspace.delete(f.id)

        await app.push([mac, simA])
        #expect(app.session(simA)?.filter == processIs("A"))
        #expect(app.workspace.displayName(for: simA.id) == "Untitled")
        #expect(app.workspace.state(for: simA.id)
            == DeviceFilterState(basedOn: nil, expression: processIs("A"), isEdited: true))
        // And across a relaunch too.
        let again = launch()
        await again.push([simA])
        #expect(again.session(simA)?.filter == processIs("A"))
        #expect(again.workspace.displayName(for: simA.id) == "Untitled")
    }

    /// Renamed while the device is away: same expression, new name.
    @Test func filterRenamedWhileDeviceAway() async {
        let app = launch()
        let f = app.library.add(name: "F", expression: processIs("A"))
        app.workspace.select(f.id, for: simA.id)
        await app.push([mac, simA])
        await app.push([mac])
        #expect(app.session(simA) == nil)

        app.workspace.rename(f.id, to: "Renamed")

        await app.push([mac, simA])
        #expect(app.session(simA)?.filter == processIs("A"))
        #expect(app.workspace.displayName(for: simA.id) == "Renamed")
        #expect(!app.workspace.state(for: simA.id).isEdited)
    }

    /// A streaming session is kept while its device is away; a save from another device
    /// reaches it, and it still has it when the device returns and streaming resumes.
    @Test func keptSessionGetsTheResavedFilter() async {
        let app = launch()
        let f = app.library.add(name: "F", expression: processIs("A"))
        app.workspace.select(f.id, for: simA.id)
        app.workspace.select(f.id, for: mac.id)
        await app.push([mac, simA])
        let s = app.session(simA)!
        s.start()
        await app.push([mac])
        #expect(app.session(simA) === s)
        #expect(s.state == .disconnected(wasStreaming: true))

        app.workspace.setExpression(processIs("C"), for: mac.id)
        app.workspace.save(for: mac.id)
        #expect(s.filter == processIs("C"))

        await app.push([mac, simA])
        #expect(app.session(simA) === s)
        #expect(s.state == .streaming)
        #expect(s.filter == processIs("C"))
    }

    /// ES §13.7: a session on A (A links B) gets the resolved tree, and rescans when B is
    /// saved from another device, though the device's own (linked) tree didn't change.
    @Test func linkedFilterChangeReachesSession() async {
        let app = launch()
        let b = app.library.add(name: "B", expression: processIs("B"))
        let a = app.library.add(name: "A", expression: .any([processIs("A"), .link(b.id)]))
        app.workspace.select(a.id, for: mac.id)
        app.workspace.select(b.id, for: simA.id)
        await app.push([mac, simA])
        let s = app.session(mac)!
        #expect(s.filter == .any([processIs("A"), processIs("B")]))
        let revision = s.revision

        app.workspace.setExpression(processIs("B2"), for: simA.id)
        app.workspace.save(for: simA.id)

        #expect(s.filter == .any([processIs("A"), processIs("B2")]))
        #expect(s.revision > revision)
        #expect(app.workspace.state(for: mac.id).expression == .any([processIs("A"), .link(b.id)]))

        // Deleting B leaves a missing link, which the session drops.
        app.workspace.delete(b.id)
        #expect(s.filter == .any([processIs("A")]))

        // A relaunch hands the new session the resolved tree too.
        let again = launch()
        await again.push([mac])
        #expect(again.session(mac)?.filter == .any([processIs("A")]))
    }
}

extension FilterWiringTests {
    /// The app adds its own step (pointing an open filter editor at the new session) after
    /// `connect`'s: both run, in order, for each new session, including a returning device's.
    @Test func sessionCreatedHandlersChain() async {
        let app = launch()
        let f = app.library.add(name: "F", expression: processIs("A"))
        app.workspace.select(f.id, for: simA.id)
        var seen: [(StreamSession, FilterExpression?)] = []
        app.registry.addSessionCreatedHandler { session in
            // `push` adds a marker device each time; only simA's sessions matter here.
            if session.device.id == simA.id { seen.append((session, session.filter)) }
        }
        await app.push([simA])
        #expect(seen.count == 1)
        #expect(seen.first?.0 === app.session(simA))
        #expect(seen.first?.1 == processIs("A"))  // the filter was set first
        await app.push([])
        #expect(app.session(simA) == nil)
        await app.push([simA])
        #expect(seen.count == 2)
        #expect(seen.last?.0 === app.session(simA))
        #expect(seen.last?.1 == processIs("A"))
    }

    /// A link is added to a device's saved filter (saved from another device) while the
    /// device is away: when it returns, its new session gets the resolved tree. A kept
    /// (streaming) session gets it at once and keeps it across the return.
    @Test func linkAddedWhileDeviceAway() async {
        let app = launch()
        let b = app.library.add(name: "B", expression: processIs("B"))
        let f = app.library.add(name: "F", expression: processIs("A"))
        for d in [mac, simA, simB] { app.workspace.select(f.id, for: d.id) }
        await app.push([mac, simA, simB])
        let kept = app.session(simB)!
        kept.start()
        await app.push([mac])
        #expect(app.session(simA) == nil)
        #expect(app.session(simB) === kept)

        app.workspace.setExpression(.any([processIs("A"), .link(b.id)]), for: mac.id)
        #expect(app.workspace.save(for: mac.id) == .saved)
        let resolved = FilterExpression.any([processIs("A"), processIs("B")])
        #expect(kept.filter == resolved)

        await app.push([mac, simA, simB])
        #expect(app.session(simA)?.filter == resolved)
        #expect(app.session(simB) === kept)
        #expect(kept.filter == resolved)
        #expect(app.workspace.state(for: simA.id).expression == .any([processIs("A"), .link(b.id)]))
    }

    /// A disabled condition on > off > on, driven through the workspace into one live session:
    /// the session's rows follow each step.
    @Test func disabledConditionOnOffOnReachesSession() async {
        let app = launch()
        await app.push([mac])
        let s = app.session(mac)!
        s.start()
        app.transport.yield((0..<30).map {
            makeEntry($0, message: $0 % 2 == 0 ? "x" : "y", process: ["A", "B", "C"][Int($0) % 3])
        })
        #expect(await eventually { s.appendedCount == 30 })
        func tree(_ messageOn: Bool) -> FilterExpression {
            .all([processIs("A"), .condition(FilterCondition(
                field: .message, match: .is, value: "x", isEnabled: messageOn))])
        }
        app.workspace.setExpression(tree(true), for: mac.id)
        #expect(await eventually { !s.isFiltering })
        #expect(s.rows.count == 5)  // A and x: ids 0, 6, 12, 18, 24

        app.workspace.setExpression(tree(false), for: mac.id)
        #expect(s.filter == tree(false))
        #expect(await eventually { !s.isFiltering })
        #expect(s.rows.count == 10)  // the message condition is ignored

        app.workspace.setExpression(tree(true), for: mac.id)
        #expect(await eventually { !s.isFiltering })
        #expect(s.rows.count == 5)
        #expect((0..<s.rows.count).allSatisfy { s.rows[$0].process == "A" && s.rows[$0].message == "x" })
    }
}
