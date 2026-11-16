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
}
