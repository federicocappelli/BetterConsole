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

    // MARK: - Links (ES §9, §13.4, §13.7)

    private func calls(_ r: Rig) -> [String] { r.changes.calls.map(\.0) }

    @Test func savingALinkedFilterUpdatesDependents() {
        let r = Rig()
        let b = r.library.add(name: "B", expression: cond("b"))
        let a = r.library.add(name: "A", expression: .all([cond("a"), .link(b.id)]))
        r.workspace.select(a.id, for: "mac")
        #expect(r.changes.calls.last?.1 == .all([cond("a"), cond("b")]))
        r.workspace.select(b.id, for: "phone")
        r.workspace.setExpression(cond("b2"), for: "phone")
        r.changes.calls.removeAll()

        r.workspace.save(for: "phone")

        #expect(calls(r) == ["mac"])
        #expect(r.changes.calls.first?.1 == .all([cond("a"), cond("b2")]))
        #expect(r.workspace.resolvedExpression(for: "mac") == .all([cond("a"), cond("b2")]))
        // The stored tree keeps the link.
        #expect(r.workspace.state(for: "mac").expression == .all([cond("a"), .link(b.id)]))
    }

    /// A save reaching both a device on the saved filter and one linking it indirectly fires
    /// once per device.
    @Test func savePropagatesThroughIndirectLinksOncePerDevice() {
        let r = Rig()
        let c = r.library.add(name: "C", expression: cond("c"))
        let b = r.library.add(name: "B", expression: .link(c.id))
        let a = r.library.add(name: "A", expression: .any([.link(b.id), .link(c.id)]))
        r.workspace.select(a.id, for: "mac")
        r.workspace.select(c.id, for: "sim")
        r.workspace.select(c.id, for: "phone")
        r.workspace.setExpression(cond("c2"), for: "phone")
        r.changes.calls.removeAll()

        r.workspace.save(for: "phone")

        #expect(calls(r).sorted() == ["mac", "sim"])
        #expect(r.workspace.resolvedExpression(for: "mac") == .any([cond("c2"), cond("c2")]))
        #expect(r.workspace.resolvedExpression(for: "sim") == cond("c2"))
    }

    @Test func deletingALinkedFilterLeavesAMissingLink() {
        let r = Rig()
        let b = r.library.add(name: "B", expression: cond("b"))
        let a = r.library.add(name: "A", expression: .all([cond("a"), .link(b.id)]))
        _ = r.library.add(name: "Noise", expression: .not(.link(b.id)))
        let top = r.library.add(name: "Top", expression: .link(a.id))
        r.workspace.select(a.id, for: "mac")
        r.workspace.setExpression(.any([.link(b.id), cond("u")]), for: "untitled")
        r.workspace.select(b.id, for: "phone")
        #expect(r.workspace.dependentsNames(of: b.id) == ["A", "Noise", "Top"])
        #expect(r.workspace.dependentsNames(of: top.id).isEmpty)
        r.changes.calls.removeAll()

        r.workspace.delete(b.id)

        #expect(calls(r).sorted() == ["mac", "untitled"])
        #expect(r.workspace.resolvedExpression(for: "mac") == .all([cond("a")]))
        #expect(r.workspace.resolvedExpression(for: "untitled") == .any([cond("u")]))
        // The phone was on B: it keeps B's tree as Untitled, unchanged.
        #expect(r.workspace.resolvedExpression(for: "phone") == cond("b"))
        // The links stay in the library as missing links.
        #expect(r.library.filter(id: a.id)?.expression == .all([cond("a"), .link(b.id)]))
        #expect(r.workspace.state(for: "untitled").expression == .any([.link(b.id), cond("u")]))
    }

    @Test func renameKeepsLinks() {
        let r = Rig()
        let b = r.library.add(name: "B", expression: cond("b"))
        let a = r.library.add(name: "A", expression: .link(b.id))
        r.workspace.select(a.id, for: "mac")
        r.changes.calls.removeAll()

        r.workspace.rename(b.id, to: "Renamed")

        #expect(r.changes.calls.isEmpty)
        #expect(r.library.filter(id: a.id)?.expression == .link(b.id))
        #expect(r.workspace.resolvedExpression(for: "mac") == cond("b"))
        #expect(r.workspace.dependentsNames(of: b.id) == ["A"])
    }

    @Test func canLinkRules() {
        let r = Rig()
        let c = r.library.add(name: "C", expression: cond("c"))
        let b = r.library.add(name: "B", expression: .link(c.id))
        let a = r.library.add(name: "A", expression: .not(.link(b.id)))
        let d = r.library.add(name: "D", expression: cond("d"))
        r.workspace.select(c.id, for: "mac")
        #expect(!r.workspace.canLink(c.id, forDevice: "mac"))   // its own filter
        #expect(!r.workspace.canLink(b.id, forDevice: "mac"))   // B links C
        #expect(!r.workspace.canLink(a.id, forDevice: "mac"))   // A links C through B
        #expect(r.workspace.canLink(d.id, forDevice: "mac"))
        r.workspace.select(a.id, for: "phone")
        #expect(r.workspace.canLink(c.id, forDevice: "phone"))
        #expect(!r.workspace.canLink(a.id, forDevice: "phone"))
        // Untitled may link anything.
        r.workspace.setExpression(cond("x"), for: "untitled")
        for id in [a.id, b.id, c.id, d.id] { #expect(r.workspace.canLink(id, forDevice: "untitled")) }
        // Untitled after its filter was deleted, too.
        r.workspace.delete(c.id)
        #expect(r.workspace.canLink(b.id, forDevice: "mac"))
    }

    @Test func saveRefusesALoop() {
        let r = Rig()
        let a = r.library.add(name: "A", expression: cond("a"))
        let b = r.library.add(name: "B", expression: .link(a.id))
        r.workspace.select(a.id, for: "mac")
        r.workspace.select(a.id, for: "sim")
        r.workspace.setExpression(.all([cond("a"), .link(b.id)]), for: "mac")
        let stored = r.persistence.stored
        r.changes.calls.removeAll()

        r.workspace.save(for: "mac")

        #expect(r.library.filter(id: a.id)?.expression == cond("a"))
        #expect(r.workspace.state(for: "mac").isEdited)
        #expect(r.persistence.stored == stored)
        #expect(r.changes.calls.isEmpty)
        #expect(r.workspace.resolvedExpression(for: "sim") == cond("a"))

        // A direct link to itself is refused as well.
        r.workspace.setExpression(.link(a.id), for: "mac")
        r.workspace.save(for: "mac")
        #expect(r.library.filter(id: a.id)?.expression == cond("a"))

        // A link that makes no loop saves.
        let c = r.library.add(name: "C", expression: cond("c"))
        r.workspace.setExpression(.link(c.id), for: "mac")
        r.workspace.save(for: "mac")
        #expect(r.library.filter(id: a.id)?.expression == .link(c.id))
    }

    @Test func relaunchResolvesLinks() {
        let r = Rig()
        let b = r.library.add(name: "B", expression: cond("b"))
        let a = r.library.add(name: "A", expression: .all([cond("a"), .link(b.id)]))
        r.workspace.select(a.id, for: "mac")
        r.workspace.setExpression(.not(.link(b.id)), for: "untitled")
        r.workspace.select(b.id, for: "phone")
        r.workspace.setExpression(cond("b2"), for: "phone")
        r.workspace.save(for: "phone")

        let relaunched = FilterWorkspace(library: r.library, persistence: r.persistence)
        #expect(relaunched.resolvedExpression(for: "mac") == .all([cond("a"), cond("b2")]))
        #expect(relaunched.resolvedExpression(for: "untitled") == .not(cond("b2")))
        #expect(relaunched.state(for: "mac").expression == .all([cond("a"), .link(b.id)]))

        // The relaunched workspace keeps propagating.
        let box = Box()
        relaunched.onExpressionChange = { id, e in box.calls.append((id, e)) }
        relaunched.setExpression(cond("b3"), for: "phone")
        box.calls.removeAll()
        relaunched.save(for: "phone")
        #expect(box.calls.map(\.0).sorted() == ["mac", "untitled"])
        #expect(relaunched.resolvedExpression(for: "mac") == .all([cond("a"), cond("b3")]))
    }

    @Test func resolveReplacesLinksAndDropsMissingAndLoops() {
        let r = Rig()
        let aID = UUID()
        let empty = r.library.add(name: "Empty", expression: nil)
        let b = r.library.add(name: "B", expression: .any([cond("b"), .link(aID)]))
        // A → B → A: a loop stored behind the workspace's back (imports can't do this either,
        // but resolution must not hang).
        r.library.update(id: b.id, expression: .any([cond("b"), .link(b.id)]))
        let c = r.library.add(name: "C", expression: .all([cond("c"), .link(b.id)]))
        let w = r.workspace

        #expect(w.resolve(nil) == nil)
        #expect(w.resolve(cond("x")) == cond("x"))
        #expect(w.resolve(.all([])) == .all([]))
        #expect(w.resolve(.link(UUID())) == nil)
        #expect(w.resolve(.not(.link(UUID()))) == nil)
        #expect(w.resolve(.link(empty.id)) == nil)
        #expect(w.resolve(.all([cond("x"), .link(UUID()), .not(.link(empty.id))])) == .all([cond("x")]))
        #expect(w.resolve(.link(b.id)) == .any([cond("b")]))
        #expect(w.resolve(.not(.link(c.id))) == .not(.all([cond("c"), .any([cond("b")])])))
        // The same filter linked twice side by side is not a loop.
        #expect(w.resolve(.all([.link(c.id), .link(c.id)]))
            == .all([.all([cond("c"), .any([cond("b")])]), .all([cond("c"), .any([cond("b")])])]))
    }

    /// An edited device that links its own filter: the link is a loop and is dropped.
    @Test func resolvedExpressionDropsALinkToTheDevicesOwnFilter() {
        let r = Rig()
        let a = r.library.add(name: "A", expression: cond("a"))
        r.workspace.select(a.id, for: "mac")
        r.workspace.setExpression(.all([cond("x"), .link(a.id)]), for: "mac")
        #expect(r.workspace.resolvedExpression(for: "mac") == .all([cond("x")]))
        #expect(r.changes.calls.last?.1 == .all([cond("x")]))
        #expect(r.workspace.resolvedExpression(for: "unknown") == nil)
    }

    /// Edits to a linked filter that are not saved don't reach devices linking it.
    @Test func unsavedEditsDoNotPropagate() {
        let r = Rig()
        let b = r.library.add(name: "B", expression: cond("b"))
        let a = r.library.add(name: "A", expression: .link(b.id))
        r.workspace.select(a.id, for: "mac")
        r.workspace.select(b.id, for: "phone")
        r.changes.calls.removeAll()
        r.workspace.setExpression(cond("b2"), for: "phone")
        r.workspace.discard(for: "phone")
        #expect(calls(r) == ["phone", "phone"])
        #expect(r.workspace.resolvedExpression(for: "mac") == cond("b"))
    }

    /// Save As of a device's tree makes a new filter nothing links yet; other devices are
    /// untouched and the device's resolved tree is unchanged, so nothing fires.
    @Test func saveAsAndDuplicateFireNothingWhenTheTreeIsUnchanged() {
        let r = Rig()
        let b = r.library.add(name: "B", expression: cond("b"))
        let a = r.library.add(name: "A", expression: .link(b.id))
        r.workspace.select(a.id, for: "mac")
        r.workspace.select(a.id, for: "phone")
        r.changes.calls.removeAll()
        _ = r.workspace.duplicate(for: "mac")
        _ = r.workspace.saveAs(name: "New", for: "mac")
        #expect(r.changes.calls.isEmpty)
        #expect(r.workspace.resolvedExpression(for: "mac") == cond("b"))
    }

    /// The editor's preview resolves like the device's session: seeded with the device's own
    /// filter, so a link that became a loop after it was made is dropped in both.
    @Test func resolveForDeviceAgreesWithResolvedExpression() {
        let r = Rig()
        let a = r.library.add(name: "A", expression: cond("a"))
        let b = r.library.add(name: "B", expression: cond("b"))
        r.workspace.select(a.id, for: "mac")
        #expect(r.workspace.canLink(b.id, forDevice: "mac"))
        let edited = FilterExpression.all([cond("x"), .link(b.id)])
        r.workspace.setExpression(edited, for: "mac")
        // Another device saves B linking A.
        r.workspace.select(b.id, for: "phone")
        r.workspace.setExpression(.any([cond("b"), .link(a.id)]), for: "phone")
        #expect(r.workspace.save(for: "phone") == .saved)

        let session = r.workspace.resolvedExpression(for: "mac")
        #expect(session == .all([cond("x"), .any([cond("b")])]))
        #expect(r.workspace.resolve(edited, forDevice: "mac") == session)
        // Unseeded, A's saved tree comes back in through B.
        #expect(r.workspace.resolve(edited) == .all([cond("x"), .any([cond("b"), cond("a")])]))
        // An Untitled device has nothing to seed.
        #expect(r.workspace.resolve(edited, forDevice: "nobody") == r.workspace.resolve(edited))
    }

    @Test func saveReportsItsOutcome() {
        let r = Rig()
        let a = r.library.add(name: "A", expression: cond("a"))
        let b = r.library.add(name: "B", expression: .link(a.id))
        r.workspace.setExpression(cond("u"), for: "untitled")
        #expect(r.workspace.save(for: "untitled") == .noBaseFilter)
        r.workspace.select(a.id, for: "mac")
        r.workspace.setExpression(.link(b.id), for: "mac")
        #expect(r.workspace.save(for: "mac") == .refusedLoop)
        #expect(r.library.filter(id: a.id)?.expression == cond("a"))
        r.workspace.setExpression(cond("a2"), for: "mac")
        #expect(r.workspace.save(for: "mac") == .saved)
        #expect(r.library.filter(id: a.id)?.expression == cond("a2"))
    }
}

extension FilterWorkspaceTests {
    /// `levels` nested exclusions around one condition: a tree `levels + 1` deep.
    private func deep(_ levels: Int) -> FilterExpression {
        var e = cond("x")
        for _ in 0..<levels { e = .not(e) }
        return e
    }

    /// The tree-depth cap (FilterFile.maxDepth) holds at the workspace too: a deeper tree is
    /// refused, so persistence and the library never get one they can't encode.
    @Test func setExpressionAndSaveRefuseTreesPastTheDepthCap() {
        let r = Rig()
        let f = r.library.add(name: "F", expression: cond("a"))
        r.workspace.select(f.id, for: "mac")
        r.changes.calls.removeAll()
        #expect(FilterFile.depth(deep(31)) == FilterFile.maxDepth)
        #expect(r.workspace.setExpression(deep(31), for: "mac"))
        #expect(r.workspace.state(for: "mac").expression == deep(31))
        r.changes.calls.removeAll()

        #expect(!r.workspace.setExpression(deep(32), for: "mac"))
        #expect(r.workspace.state(for: "mac").expression == deep(31))
        #expect(r.changes.calls.isEmpty)
        #expect(r.persistence.stored["mac"]?.expression == deep(31))

        // A saved filter already past the cap (written before the cap): Save refuses.
        let tooDeep = r.library.add(name: "Deep", expression: deep(32))
        r.workspace.select(tooDeep.id, for: "phone")
        #expect(r.workspace.save(for: "phone") == .tooDeep)
        #expect(r.workspace.save(for: "mac") == .saved)
        #expect(r.library.filter(id: f.id)?.expression == deep(31))
    }

    /// The delete prompt names only the filters that link the deleted one themselves.
    @Test func directDependentsNamesListsOnlyDirectLinks() {
        let r = Rig()
        let b = r.library.add(name: "B", expression: cond("b"))
        let a = r.library.add(name: "A", expression: .all([cond("a"), .link(b.id)]))
        _ = r.library.add(name: "noise", expression: .not(.link(b.id)))
        _ = r.library.add(name: "Top", expression: .link(a.id))
        #expect(r.workspace.directDependentsNames(of: b.id) == ["A", "noise"])
        #expect(r.workspace.directDependentsNames(of: a.id) == ["Top"])
        #expect(r.workspace.dependentsNames(of: b.id) == ["A", "noise", "Top"])
    }
}
