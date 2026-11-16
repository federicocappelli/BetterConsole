import Foundation
import Testing
@testable import BCFilter

final class MemoryPersistence: DeviceFilterPersistence {
    var stored: [String: DeviceFilterState] = [:]
    func load() -> [String: DeviceFilterState] { stored }
    func save(_ states: [String: DeviceFilterState]) { stored = states }
}

@MainActor @Suite struct FilterWorkspaceTests {
    private func cond(_ v: String) -> FilterExpression {
        .condition(FilterCondition(field: .process, match: .is, value: v))
    }

    @MainActor private struct Rig {
        var library = FilterLibrary(storage: FakeStorage())
        var persistence = MemoryPersistence()
        var workspace: FilterWorkspace
        var changes: Box
        init() {
            let box = Box()
            workspace = FilterWorkspace(library: library, persistence: persistence)
            workspace.onExpressionChange = { id, e in box.calls.append((id, e)) }
            changes = box
        }
    }

    @MainActor final class Box { var calls: [(String, FilterExpression?)] = [] }

    @Test func saveAsSwitchesOnlyThisDevice() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("A"))
        r.workspace.select(f.id, for: "mac")
        r.workspace.select(f.id, for: "phone")
        r.workspace.setExpression(cond("B"), for: "mac")
        let g = r.workspace.saveAs(name: "G", for: "mac")
        #expect(r.workspace.state(for: "mac") == DeviceFilterState(basedOn: g.id, expression: cond("B"), isEdited: false))
        #expect(r.workspace.state(for: "phone").basedOn == f.id)
        #expect(r.library.filter(id: f.id)?.expression == cond("A"))
        #expect(r.library.filter(id: g.id)?.expression == cond("B"))
        #expect(r.workspace.displayName(for: "mac") == "G")
    }

    @Test func savePropagatesToUneditedOnly() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("A"))
        for d in ["mac", "phone", "sim"] { r.workspace.select(f.id, for: d) }
        r.workspace.setExpression(cond("phone edit"), for: "phone")
        r.workspace.setExpression(cond("New"), for: "mac")
        r.changes.calls.removeAll()
        r.workspace.save(for: "mac")
        #expect(r.library.filter(id: f.id)?.expression == cond("New"))
        #expect(r.workspace.state(for: "mac").isEdited == false)
        #expect(r.workspace.state(for: "sim").expression == cond("New"))
        #expect(r.workspace.state(for: "phone") == DeviceFilterState(basedOn: f.id, expression: cond("phone edit"), isEdited: true))
        #expect(r.changes.calls.map(\.0) == ["sim"])
    }

    /// Save on an Untitled device (the bar offers Save As instead) does nothing, in Release too.
    @Test func saveWithoutABaseFilterDoesNothing() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("A"))
        r.workspace.setExpression(cond("B"), for: "mac")
        let before = r.workspace.state(for: "mac")
        let stored = r.persistence.stored
        let filters = r.library.filters
        r.changes.calls.removeAll()
        r.workspace.save(for: "mac")
        #expect(r.workspace.state(for: "mac") == before)
        #expect(r.persistence.stored == stored)
        #expect(r.library.filters == filters)
        #expect(r.library.filter(id: f.id)?.expression == cond("A"))
        #expect(r.changes.calls.isEmpty)
    }

    @Test func deleteMakesDevicesUntitledEdited() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("A"))
        r.workspace.select(f.id, for: "mac")
        r.workspace.delete(f.id)
        #expect(r.workspace.state(for: "mac") == DeviceFilterState(basedOn: nil, expression: cond("A"), isEdited: true))
        #expect(r.workspace.displayName(for: "mac") == "Untitled")
        #expect(r.library.filter(id: f.id) == nil)
    }

    @Test func duplicateMovesDeviceToCopyWithEdits() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("A"))
        r.workspace.select(f.id, for: "mac")
        r.workspace.setExpression(cond("B"), for: "mac")
        let copy = r.workspace.duplicate(for: "mac")
        #expect(copy.name == "F copy")
        #expect(copy.expression == cond("A"))
        #expect(r.workspace.state(for: "mac") == DeviceFilterState(basedOn: copy.id, expression: cond("B"), isEdited: true))
        #expect(r.library.filter(id: f.id)?.expression == cond("A"))
    }

    @Test func discardRestoresSaved() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("A"))
        r.workspace.select(f.id, for: "mac")
        r.workspace.setExpression(cond("B"), for: "mac")
        r.workspace.discard(for: "mac")
        #expect(r.workspace.state(for: "mac") == DeviceFilterState(basedOn: f.id, expression: cond("A"), isEdited: false))
        r.workspace.setExpression(cond("C"), for: "untitled")
        r.workspace.discard(for: "untitled")
        #expect(r.workspace.state(for: "untitled") == .empty)
    }

    @Test func restoreAcrossRelaunch() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("A"))
        let g = r.library.add(name: "G", expression: cond("G"))
        r.workspace.select(f.id, for: "mac")
        r.workspace.select(g.id, for: "phone")
        r.workspace.setExpression(cond("edit"), for: "phone")
        r.workspace.select(f.id, for: "sim")
        r.library.delete(id: g.id)   // behind the workspace's back
        r.library.update(id: f.id, expression: cond("A2"))

        let relaunched = FilterWorkspace(library: r.library, persistence: r.persistence)
        #expect(relaunched.state(for: "mac") == DeviceFilterState(basedOn: f.id, expression: cond("A2"), isEdited: false))
        #expect(relaunched.state(for: "sim").expression == cond("A2"))
        #expect(relaunched.state(for: "phone") == DeviceFilterState(basedOn: nil, expression: cond("edit"), isEdited: true))
    }

    @Test func restoreDeletedBasedUneditedEmptyIsNotEdited() {
        let p = MemoryPersistence()
        let id = UUID()
        p.stored["mac"] = DeviceFilterState(basedOn: id, expression: nil, isEdited: false)
        let w = FilterWorkspace(library: FilterLibrary(storage: FakeStorage()), persistence: p)
        #expect(w.state(for: "mac") == .empty)
    }

    @Test func selectClearsEdits() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("A"))
        r.workspace.select(f.id, for: "mac")
        r.workspace.setExpression(cond("B"), for: "mac")
        r.workspace.select(f.id, for: "mac")
        #expect(r.workspace.state(for: "mac") == DeviceFilterState(basedOn: f.id, expression: cond("A"), isEdited: false))
        r.workspace.setExpression(cond("B"), for: "mac")
        r.workspace.select(nil, for: "mac")
        #expect(r.workspace.state(for: "mac") == .empty)
    }

    @Test func expressionChangeCallbackAndPersistence() {
        let r = Rig()
        r.workspace.setExpression(cond("X"), for: "mac")
        #expect(r.changes.calls.count == 1)
        #expect(r.persistence.stored["mac"]?.expression == cond("X"))
        r.workspace.select(nil, for: "mac")
        #expect(r.changes.calls.last?.1 == nil)
    }

    @Test func userDefaultsPersistenceRoundTrip() {
        let suite = "FilterWorkspaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = UserDefaultsDeviceFilterPersistence(defaults: defaults)
        #expect(p.load().isEmpty)
        let state = DeviceFilterState(basedOn: UUID(), expression: cond("A"), isEdited: true)
        p.save(["mac": state])
        #expect(p.load() == ["mac": state])
    }

    @Test func renameShowsNewNameOnDevices() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("A"))
        r.workspace.select(f.id, for: "mac")
        r.workspace.select(f.id, for: "phone")
        r.workspace.rename(f.id, to: "Renamed")
        #expect(r.workspace.displayName(for: "mac") == "Renamed")
        #expect(r.workspace.displayName(for: "phone") == "Renamed")
    }

    @Test func duplicateTwiceGetsUniqueName() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("A"))
        r.workspace.select(f.id, for: "mac")
        r.workspace.select(f.id, for: "phone")
        let first = r.workspace.duplicate(for: "mac")
        r.library.rename(id: first.id, to: "F copy")
        let second = r.workspace.duplicate(for: "phone")
        #expect(second.name == "F copy 2")
    }
}
