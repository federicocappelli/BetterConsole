import Foundation
import Testing
@testable import BCFilter

@MainActor @Suite struct FilterEditorModelTests {
    private static func cond(_ v: String, _ field: FilterField = .process) -> FilterCondition {
        FilterCondition(field: field, match: .is, value: v)
    }

    private static func c(_ v: String) -> FilterExpression { .condition(cond(v)) }

    private func cond(_ v: String, _ field: FilterField = .process) -> FilterCondition { Self.cond(v, field) }
    private func c(_ v: String) -> FilterExpression { Self.c(v) }

    @MainActor private struct Rig {
        let library = FilterLibrary(storage: FakeStorage())
        let workspace: FilterWorkspace
        init() { workspace = FilterWorkspace(library: library, persistence: MemoryPersistence()) }

        /// An editor on `device`, after giving the device `expression` (Untitled) or selecting
        /// `filter`.
        func editor(
            _ expression: FilterExpression? = nil, on filter: SavedFilter? = nil, device: String = "mac"
        ) -> FilterEditorModel {
            if let filter { workspace.select(filter.id, for: device) }
            if let expression { workspace.setExpression(expression, for: device) }
            return FilterEditorModel(deviceID: device, workspace: workspace, library: library)
        }
    }

    /// Lets the editor see workspace changes (it is told about them on the main actor, after
    /// the change).
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func members(_ m: FilterEditorModel) -> [EditorNode] { m.root.children }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterEditorModelTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - Tree and group kinds

    @Test func startsFromTheDevicesUnresolvedExpression() {
        let r = Rig()
        let n = r.library.add(name: "Noise", expression: c("n"))
        let m = r.editor(.all([c("a"), .link(n.id)]))
        #expect(m.expression == .all([c("a"), .link(n.id)]))
        #expect(m.root.kind.groupKind == .allOf)
        #expect(members(m).count == 2)
        #expect(!m.isEdited)
        #expect(!m.canUndo && !m.canRedo)
        #expect(m.canApply)
    }

    @Test func emptyAndSingleRootsReadAsAnAllOfGroup() {
        let r = Rig()
        let empty = r.editor(device: "empty")
        #expect(empty.root.kind.groupKind == .allOf && empty.root.children.isEmpty)
        #expect(empty.expression == nil)
        let single = r.editor(c("a"), device: "single")
        #expect(single.root.kind.groupKind == .allOf && single.root.children.count == 1)
        #expect(single.expression == c("a"))
        #expect(!single.isEdited)
    }

    /// ES §13.1: the four group kinds and how other NOT shapes read.
    @Test func groupKindsRoundTripThroughExpression() {
        let r = Rig()
        let link = FilterExpression.link(UUID())
        let exact: [(FilterExpression, GroupKind)] = [
            (.all([c("a"), c("b")]), .allOf),
            (.any([c("a"), c("b")]), .anyOf),
            (.not(.any([c("a"), c("b")])), .noneOf),
            (.not(.all([c("a"), c("b")])), .notAllOf),
            (.not(c("a")), .noneOf),
            (.not(link), .noneOf),
            (.not(.any([.all([c("a"), c("b")])])), .noneOf),
            (.not(.all([c("a")])), .notAllOf),
            (.all([c("a"), .not(.any([c("b"), c("c")])), .not(.all([c("d"), .any([])])), .not(c("e"))]), .allOf),
        ]
        for (i, (e, kind)) in exact.enumerated() {
            let m = r.editor(e, device: "d\(i)")
            #expect(m.root.kind.groupKind == kind, "\(e)")
            #expect(m.expression == e, "\(e)")
            #expect(!m.isEdited, "\(e)")
        }
        // Other NOT shapes read in their builder form and mean the same.
        let normalised: [(FilterExpression, FilterExpression, GroupKind)] = [
            (.not(.not(.any([c("a"), c("b")]))), .any([c("a"), c("b")]), .anyOf),
            (.not(.any([c("a")])), .not(c("a")), .noneOf),
            (.not(.not(c("a"))), c("a"), .allOf),
        ]
        for (i, (e, read, kind)) in normalised.enumerated() {
            let m = r.editor(e, device: "n\(i)")
            #expect(m.root.kind.groupKind == kind, "\(e)")
            #expect(m.expression == read, "\(e)")
            #expect(!m.isEdited, "\(e)")
        }
        // Nested: a None of with one condition, and a Not all of.
        let m = r.editor(.any([.not(c("x")), .not(.all([c("y"), c("z")]))]), device: "nested")
        #expect(m.root.children.map { $0.kind.groupKind } == [.noneOf, .notAllOf])
        #expect(m.root.children[0].children.map(\.kind) == [.condition(cond("x"))])
    }

    // MARK: - Coalesced typing (R16)

    private func typing(_ m: FilterEditorModel, _ id: UUID, _ base: FilterCondition, _ values: [String]) {
        for v in values {
            var changed = base
            changed.value = v
            m.update(id, condition: changed, coalescing: true)
        }
    }

    /// Typing a value is one step, however many keystrokes it takes.
    @Test func typingInOneValueFieldIsOneStep() {
        let r = Rig()
        let m = r.editor(c("a"))
        let id = members(m)[0].id
        typing(m, id, cond("a"), ["ab", "abc", "abcd"])
        #expect(m.expression == c("abcd"))
        m.undo()
        #expect(m.expression == c("a"))
        #expect(!m.canUndo)
        m.redo()
        #expect(m.expression == c("abcd"))
    }

    /// Ending the field's editing, another node, another value field, another action, undo or
    /// a text edit each start a new step.
    @Test func coalescingBreaks() {
        let r = Rig()
        let m = r.editor(.all([c("a"), c("b")]))
        let (a, b) = (members(m)[0].id, members(m)[1].id)

        typing(m, a, cond("a"), ["a1", "a12"])
        m.endCoalescing()
        typing(m, a, cond("a12"), ["a123"])
        m.undo()
        #expect(m.expression == .all([c("a12"), c("b")]))
        m.undo()
        #expect(m.expression == .all([c("a"), c("b")]))
        m.redo()
        m.redo()

        // Another node.
        typing(m, b, cond("b"), ["b1"])
        m.undo()
        #expect(m.expression == .all([c("a123"), c("b")]))
        m.redo()

        // Another value field of the same node (Extra data's key, then its value).
        var extra = FilterCondition(field: .extra, match: .is, value: "", key: "")
        m.update(b, condition: extra)
        extra.key = "k"
        m.update(b, condition: extra, coalescing: true)
        extra.value = "v"
        m.update(b, condition: extra, coalescing: true)
        m.undo()
        #expect(m.node(b)?.kind == .condition(FilterCondition(field: .extra, match: .is, value: "", key: "k")))
        m.redo()

        // Another action in between.
        typing(m, a, cond("a123"), ["x"])
        m.setEnabled(b, false)
        typing(m, a, cond("x"), ["xy"])
        m.undo()
        #expect(m.node(a)?.kind == .condition(cond("x")))
        #expect(m.node(b)?.isEnabled == false)

        // Undo breaks the run: typing again after undo is a new step.
        typing(m, a, cond("x"), ["xz"])
        m.undo()
        #expect(m.node(a)?.kind == .condition(cond("x")))

        // A text edit breaks the run.
        typing(m, a, cond("x"), ["x1"])
        m.textDidChange(m.text.text + "\nAND process == \"t\"")
        m.endTextEditing()
        typing(m, a, cond("x1"), ["x12"])
        m.undo()
        #expect(m.node(a)?.kind == .condition(cond("x1")))
    }

    /// Typing back to where the run started leaves no empty step behind.
    @Test func typingBackToTheStartLeavesNoStep() {
        let r = Rig()
        let m = r.editor(c("a"))
        let id = members(m)[0].id
        typing(m, id, cond("a"), ["ab", "a"])
        #expect(!m.canUndo)
        typing(m, id, cond("a"), ["ac"])
        m.undo()
        #expect(m.expression == c("a"))
    }

    // MARK: - Edits, undo and redo

    @Test func addEachKindAndUndoRedo() throws {
        let r = Rig()
        let n = r.library.add(name: "Noise", expression: c("n"))
        let m = r.editor(c("a"))
        let group = try #require(m.add(.group(.anyOf), to: m.root.id))
        #expect(m.expression == .all([c("a"), .any([])]))
        let inner = try #require(m.add(.condition(cond("b")), to: group))
        #expect(m.node(inner)?.kind == .condition(cond("b")))
        #expect(m.expression == .all([c("a"), .any([c("b")])]))
        #expect(m.add(.link(n.id), to: m.root.id) != nil)
        #expect(m.expression == .all([c("a"), .any([c("b")]), .link(n.id)]))
        #expect(m.isEdited)
        // Adding to something that isn't a group does nothing.
        #expect(m.add(.condition(cond("x")), to: inner) == nil)

        m.undo()
        #expect(m.expression == .all([c("a"), .any([c("b")])]))
        m.undo()
        m.undo()
        #expect(m.expression == c("a"))
        #expect(!m.canUndo && m.canRedo)
        #expect(!m.isEdited)
        m.redo(); m.redo(); m.redo()
        #expect(m.expression == .all([c("a"), .any([c("b")]), .link(n.id)]))
        #expect(!m.canRedo)
        // A new edit clears redo.
        m.undo()
        m.add(.condition(FilterEditorModel.newCondition), to: m.root.id)
        #expect(!m.canRedo)
        #expect(m.expression == .all([c("a"), .any([c("b")]), .condition(FilterEditorModel.newCondition)]))
    }

    @Test func updateAndUndo() {
        let r = Rig()
        let m = r.editor(.all([c("a"), c("b")]))
        let a = members(m)[0].id
        m.update(a, condition: cond("z"))
        #expect(m.expression == .all([c("z"), c("b")]))
        #expect(members(m)[0].id == a)
        // No change and non-conditions are not steps.
        m.update(a, condition: cond("z"))
        m.update(m.root.id, condition: cond("q"))
        m.undo()
        #expect(m.expression == .all([c("a"), c("b")]))
        #expect(!m.canUndo)
        m.redo()
        #expect(m.expression == .all([c("z"), c("b")]))
    }

    @Test func setGroupKindAndUndo() {
        let r = Rig()
        let m = r.editor(.all([c("a"), c("b")]))
        m.setGroupKind(m.root.id, .anyOf)
        #expect(m.expression == .any([c("a"), c("b")]))
        m.setGroupKind(m.root.id, .noneOf)
        #expect(m.expression == .not(.any([c("a"), c("b")])))
        m.setGroupKind(m.root.id, .notAllOf)
        #expect(m.expression == .not(.all([c("a"), c("b")])))
        m.setGroupKind(members(m)[0].id, .anyOf)  // a condition: nothing
        m.undo()
        #expect(m.expression == .not(.any([c("a"), c("b")])))
        m.undo(); m.undo()
        #expect(m.expression == .all([c("a"), c("b")]))
        #expect(!m.canUndo)
        m.redo()
        #expect(m.expression == .any([c("a"), c("b")]))
    }

    /// Links can't be disabled (R7), nor groups; only conditions are.
    @Test func setEnabledOnlyOnConditions() {
        let r = Rig()
        let n = r.library.add(name: "Noise", expression: c("n"))
        let m = r.editor(.all([c("a"), .link(n.id), .any([c("b")])]))
        let (a, link, group) = (members(m)[0].id, members(m)[1].id, members(m)[2].id)
        m.setEnabled(a, false)
        var off = cond("a"); off.isEnabled = false
        #expect(m.expression == .all([.condition(off), .link(n.id), .any([c("b")])]))
        #expect(m.node(a)?.isEnabled == false)
        m.setEnabled(link, false)
        m.setEnabled(group, false)
        m.setEnabled(a, false)
        #expect(m.node(link)?.isEnabled == true)
        m.undo()
        #expect(m.expression == .all([c("a"), .link(n.id), .any([c("b")])]))
        #expect(!m.canUndo)
        m.redo()
        #expect(m.node(a)?.isEnabled == false)
    }

    @Test func duplicateGivesFreshIDs() {
        let r = Rig()
        let m = r.editor(.all([c("a"), .any([c("b"), c("c")])]))
        let group = members(m)[1]
        m.duplicate(group.id)
        #expect(m.expression == .all([c("a"), .any([c("b"), c("c")]), .any([c("b"), c("c")])]))
        let copy = members(m)[2]
        #expect(copy.id != group.id)
        #expect(Set(copy.children.map(\.id)).isDisjoint(with: group.children.map(\.id)))
        m.duplicate(m.root.id)  // the root has nowhere to go
        m.duplicate(members(m)[0].id)
        #expect(m.expression == .all([c("a"), c("a"), .any([c("b"), c("c")]), .any([c("b"), c("c")])]))
        m.undo(); m.undo()
        #expect(m.expression == .all([c("a"), .any([c("b"), c("c")])]))
        #expect(!m.canUndo)
    }

    @Test func deleteAndUndoKeepsIDs() {
        let r = Rig()
        let m = r.editor(.all([c("a"), .any([c("b"), c("c")])]))
        let b = members(m)[1].children[0].id
        m.delete(b)
        #expect(m.expression == .all([c("a"), .any([c("c")])]))
        #expect(m.node(b) == nil)
        m.delete(m.root.id)
        m.undo()
        #expect(m.expression == .all([c("a"), .any([c("b"), c("c")])]))
        #expect(m.node(b) != nil)
        #expect(!m.canUndo)
    }

    @Test func wrapInGroupAndUngroup() {
        let r = Rig()
        let m = r.editor(.all([c("a"), c("b"), c("c")]))
        let b = members(m)[1].id
        let group = m.wrapInGroup(b)
        // A one-member group made in the builder is kept (R5).
        #expect(m.expression == .all([c("a"), .all([c("b")]), c("c")]))
        #expect(group.flatMap(m.node)?.children.map(\.id) == [b])
        m.wrapInGroup(m.root.id)
        if let group { m.ungroup(group) }
        #expect(m.expression == .all([c("a"), c("b"), c("c")]))
        m.undo()
        #expect(m.expression == .all([c("a"), .all([c("b")]), c("c")]))
        m.undo()
        #expect(m.expression == .all([c("a"), c("b"), c("c")]))
        #expect(!m.canUndo)
    }

    @Test func ungroupSplicesMembersInPlace() {
        let r = Rig()
        let m = r.editor(.all([c("a"), .not(.any([c("b"), c("c")])), c("d")]))
        m.ungroup(members(m)[1].id)
        #expect(m.expression == .all([c("a"), c("b"), c("c"), c("d")]))
        m.ungroup(m.root.id)  // the root stays
        m.ungroup(members(m)[0].id)  // a condition: nothing
        m.undo()
        #expect(m.expression == .all([c("a"), .not(.any([c("b"), c("c")])), c("d")]))
        #expect(!m.canUndo)
    }

    @Test func moveByOffset() {
        let r = Rig()
        let m = r.editor(.all([c("a"), c("b"), c("c")]))
        let a = members(m)[0].id
        m.move(a, by: 1)
        #expect(m.expression == .all([c("b"), c("a"), c("c")]))
        m.move(a, by: 1)
        #expect(m.expression == .all([c("b"), c("c"), c("a")]))
        m.move(a, by: 1)  // already last
        m.move(a, by: -5)  // out of range
        m.move(m.root.id, by: 1)
        m.undo()
        #expect(m.expression == .all([c("b"), c("a"), c("c")]))
        m.undo()
        #expect(m.expression == .all([c("a"), c("b"), c("c")]))
        #expect(!m.canUndo)
    }

    @Test func moveToGroup() {
        let r = Rig()
        let m = r.editor(.all([c("a"), .any([c("b"), c("c")]), c("d")]))
        let (a, group, d) = (members(m)[0].id, members(m)[1].id, members(m)[2].id)
        m.move(d, to: group, index: 1)
        #expect(m.expression == .all([c("a"), .any([c("b"), c("d"), c("c")])]))
        // Within the same group the index is a drop position in the list before the move.
        m.move(a, to: m.root.id, index: 2)
        #expect(m.expression == .all([.any([c("b"), c("d"), c("c")]), c("a")]))
        // Out-of-range indexes are clamped.
        m.move(a, to: group, index: 99)
        #expect(m.expression == .all([.any([c("b"), c("d"), c("c"), c("a")])]))
        // A group can't go inside itself, nor the root anywhere.
        let inner = m.add(.group(.allOf), to: group)!
        m.move(group, to: inner, index: 0)
        m.move(group, to: group, index: 0)
        m.move(m.root.id, to: group, index: 0)
        #expect(m.expression == .all([.any([c("b"), c("d"), c("c"), c("a"), .all([])])]))
        m.undo(); m.undo(); m.undo(); m.undo()
        #expect(m.expression == .all([c("a"), .any([c("b"), c("c")]), c("d")]))
        #expect(!m.canUndo)
    }

    // MARK: - Text

    @Test func textFollowsTheTreeAndMapsRanges() throws {
        let r = Rig()
        let m = r.editor(.all([c("a"), .any([c("b"), c("c")])]))
        #expect(m.text.text == PredicateWriter.write(m.expression, nameForLink: { _ in nil }).text)
        let b = members(m)[1].children[0].id
        let range = try #require(m.textRange(for: b))
        #expect(m.text.text[range].contains("\"b\""))
        #expect(m.nodeID(at: range.lowerBound) == b)
        m.update(b, condition: cond("bee"))
        #expect(m.text.text.contains("\"bee\""))
    }

    /// ES §8.4 (R12): each parse after a pause in typing that changes the tree is one step;
    /// leaving the text only reflows it.
    @Test func eachTreeChangingParseIsOneUndoStep() {
        let r = Rig()
        let m = r.editor(c("a"))
        let original = m.text.text
        m.textDidChange(#"process == "b""#)
        #expect(m.expression == c("b"))
        m.textDidChange(#"process == "#)  // an error in between keeps the tree, no step
        #expect(m.expression == c("b"))
        m.textDidChange(#"process == "bc""#)
        #expect(m.expression == c("bc"))
        m.textDidChange(#"process  ==  "bc""#)  // same tree: no step
        // Not reflowed while typing.
        #expect(m.text.text == #"process  ==  "bc""#)
        m.endTextEditing()
        #expect(m.text.text == PredicateWriter.write(c("bc"), nameForLink: { _ in nil }).text)
        m.undo()
        #expect(m.expression == c("b"))
        m.undo()
        #expect(m.expression == c("a"))
        #expect(m.text.text == original)
        #expect(!m.canUndo)
        m.redo()
        #expect(m.expression == c("b"))
        m.redo()
        #expect(m.expression == c("bc"))
        #expect(!m.canRedo)
    }

    /// Text being typed that has an error, or isn't the canonical layout, counts as unsaved
    /// work: a bar change raises the banner instead of replacing it.
    @Test func typedTextIsUnsavedWorkAgainstABarChange() async {
        let r = Rig()
        let m = r.editor(c("a"))
        #expect(!m.hasUnsavedChanges)
        m.textDidChange(#"process == "a" AND"#)
        #expect(m.hasUnsavedChanges)
        #expect(!m.isEdited)
        r.workspace.setExpression(c("bar"), for: "mac")
        await settle()
        #expect(m.externalChange)
        #expect(m.textError != nil)
        #expect(m.text.text == #"process == "a" AND"#)
        #expect(m.expression == c("a"))

        // Raw text that means the device's tree but isn't laid out canonically counts too.
        let n = r.editor(c("a"), device: "phone")
        n.textDidChange(#"process   ==   "a""#)
        #expect(n.textError == nil)
        #expect(n.hasUnsavedChanges)
        r.workspace.setExpression(c("bar"), for: "phone")
        await settle()
        #expect(n.externalChange)
        #expect(n.text.text == #"process   ==   "a""#)
        n.endTextEditing()
        n.reloadFromDevice()
        #expect(!n.hasUnsavedChanges)
    }

    /// Ids follow content, not position: removing the first of three conditions in the text
    /// keeps the other two rows' ids.
    @Test func textEditKeepsIDsByContent() {
        let r = Rig()
        let n = r.library.add(name: "Noise", expression: c("n"))
        let m = r.editor(.all([c("a"), c("b"), c("c")]))
        let ids = members(m).map(\.id)
        m.textDidChange(PredicateWriter.write(.all([c("b"), c("c")]), nameForLink: { _ in nil }).text)
        #expect(members(m).map(\.id) == [ids[1], ids[2]])
        // A changed condition keeps its row by position among conditions; a link never takes
        // a condition's id.
        m.textDidChange(PredicateWriter.write(.all([.link(n.id), c("b2"), c("c")]), nameForLink: { _ in "Noise" }).text)
        #expect(members(m)[1].id == ids[1])
        #expect(members(m)[2].id == ids[2])
        #expect(!ids.contains(members(m)[0].id))
    }

    /// R13: rows and text map to each other while the text isn't the canonical layout.
    @Test func rangesWorkOnRawText() throws {
        let r = Rig()
        let m = r.editor(c("a"))
        let raw = "process   ==  \"a\"\n   or  (processIdentifier  >  5  &&  category == \"x\")"
        m.textDidChange(raw)
        #expect(m.textError == nil)
        #expect(m.text.text == raw)
        let pid = members(m)[1].children[0].id
        let range = try #require(m.textRange(for: pid))
        #expect(m.text.text[range] == "processIdentifier  >  5")
        #expect(m.nodeID(at: range.lowerBound) == pid)
        let first = try #require(m.textRange(for: members(m)[0].id))
        #expect(m.text.text[first] == #"process   ==  "a""#)
        let group = try #require(m.textRange(for: members(m)[1].id))
        #expect(m.text.text[group] == #"processIdentifier  >  5  &&  category == "x""#)
    }

    /// Following the device doesn't touch the undo stack.
    @Test func followingTheDeviceKeepsTheUndoHistory() async {
        let r = Rig()
        let m = r.editor(c("a"))
        m.add(.condition(cond("b")), to: m.root.id)
        m.apply()
        m.undo()
        m.redo()
        #expect(m.canUndo && !m.canRedo)
        r.workspace.setExpression(c("bar"), for: "mac")
        await settle()
        #expect(m.expression == c("bar"))
        #expect(m.canUndo && !m.canRedo)
        m.undo()
        #expect(m.expression == c("a"))
        #expect(!m.canUndo)
    }

    @Test func addRefusesALinkToAMissingFilter() {
        let r = Rig()
        let m = r.editor(c("a"))
        #expect(m.add(.link(UUID()), to: m.root.id) == nil)
        #expect(!m.canUndo)
    }

    /// Typing text that means the same tree changes nothing and is not a step.
    @Test func textThatReadsTheSameIsNotAStep() {
        let r = Rig()
        let m = r.editor(.all([c("a"), c("b")]))
        let ids = members(m).map(\.id)
        m.textDidChange(m.text.text + "   ")
        m.endTextEditing()
        #expect(!m.canUndo)
        #expect(members(m).map(\.id) == ids)
    }

    @Test func invalidTextKeepsTheTreeAndBlocksApply() throws {
        let r = Rig()
        let f = r.library.add(name: "F", expression: c("a"))
        let m = r.editor(on: f)
        m.update(members(m)[0].id, condition: cond("mine"))
        m.textDidChange(#"process == "x" AND"#)
        #expect(m.textError != nil)
        #expect(!m.canApply)
        #expect(m.expression == c("mine"))
        #expect(m.text.text == #"process == "x" AND"#)
        // Leaving the text keeps what the user wrote while it has an error.
        m.endTextEditing()
        #expect(m.text.text == #"process == "x" AND"#)

        m.apply()
        #expect(r.workspace.state(for: "mac").expression == c("a"))
        #expect(m.save() == .textHasError)
        #expect(r.library.filter(id: f.id)?.expression == c("a"))
        #expect(m.saveAs(name: "New") == nil)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: FilterEditorModel.EditorError.textHasError) {
            try m.export(to: dir.appendingPathComponent("x.json"), format: .json)
        }

        m.textDidChange(#"process == "x""#)
        #expect(m.textError == nil)
        #expect(m.canApply)
        #expect(m.expression == c("x"))
    }

    /// A builder change rewrites the text, dropping a text error.
    @Test func builderEditAfterATextErrorRewritesTheText() {
        let r = Rig()
        let m = r.editor(.all([c("a"), c("b")]))
        m.textDidChange("process ==")
        m.delete(members(m)[1].id)
        #expect(m.textError == nil)
        #expect(m.text.text == PredicateWriter.write(c("a"), nameForLink: { _ in nil }).text)
    }

    @Test func endTextEditingCanonicalises() {
        let r = Rig()
        let m = r.editor(c("a"))
        let raw = "process    ==  \"b\"     and   processIdentifier>5"
        m.textDidChange(raw)
        #expect(m.textError == nil)
        #expect(m.text.text == raw)
        m.endTextEditing()
        let canonical = PredicateWriter.write(m.expression, nameForLink: { _ in nil })
        #expect(m.text.text == canonical.text)
        #expect(m.text.text != raw)
        #expect(m.textRange(for: members(m)[1].id) != nil)
    }

    /// R5: a one-member group made in the builder lasts until the text is edited.
    @Test func oneMemberGroupSurvivesUntilTheTextIsEdited() {
        let r = Rig()
        let m = r.editor(.all([c("a"), c("b")]))
        m.wrapInGroup(members(m)[1].id)
        m.endTextEditing()
        #expect(m.expression == .all([c("a"), .all([c("b")])]))
        m.textDidChange(m.text.text)
        #expect(m.expression == .all([c("a"), c("b")]))
        m.undo()
        #expect(m.expression == .all([c("a"), .all([c("b")])]))
    }

    @Test func textLinksResolveByNameAndRefuseLoops() {
        let r = Rig()
        let a = r.library.add(name: "A", expression: c("a"))
        let b = r.library.add(name: "B", expression: .link(a.id))
        let n = r.library.add(name: "Noise", expression: c("n"))
        let m = r.editor(on: a)
        m.textDidChange(#"filter == "noise""#)
        #expect(m.expression == .link(n.id))
        m.textDidChange(#"filter == "B""#)
        #expect(m.textError?.message.contains("include itself") == true)
        #expect(m.expression == .link(n.id))
        _ = b
    }

    // MARK: - The device's filter changing elsewhere

    @Test func externalChangeBannerOnBarEdit() async {
        let r = Rig()
        let f = r.library.add(name: "F", expression: c("a"))
        let m = r.editor(on: f)
        m.update(members(m)[0].id, condition: cond("mine"))
        #expect(m.isEdited)
        r.workspace.setExpression(c("bar"), for: "mac")
        await settle()
        #expect(m.externalChange)
        #expect(m.expression == c("mine"))
        // Changes to other devices don't count.
        m.keepMine()
        r.workspace.setExpression(c("other"), for: "phone")
        await settle()
        #expect(!m.externalChange)

        r.workspace.setExpression(c("bar 2"), for: "mac")
        await settle()
        #expect(m.externalChange)
        m.reloadFromDevice()
        #expect(!m.externalChange)
        #expect(m.expression == c("bar 2"))
        #expect(!m.isEdited)
        // Reload is a step.
        m.undo()
        #expect(m.expression == c("mine"))
        #expect(m.isEdited)
    }

    @Test func keepMineThenApply() async {
        let r = Rig()
        let f = r.library.add(name: "F", expression: c("a"))
        let g = r.library.add(name: "G", expression: c("g"))
        let m = r.editor(on: f)
        m.update(members(m)[0].id, condition: cond("mine"))
        r.workspace.select(g.id, for: "mac")  // picking another saved filter
        await settle()
        #expect(m.externalChange)
        m.keepMine()
        #expect(!m.externalChange)
        #expect(m.expression == c("mine"))
        m.apply()
        #expect(r.workspace.state(for: "mac") == DeviceFilterState(basedOn: g.id, expression: c("mine"), isEdited: true))
        await settle()
        #expect(!m.externalChange)
        #expect(!m.isEdited)
    }

    /// With nothing edited, the editor follows the device silently.
    @Test func uneditedEditorFollowsTheDevice() async {
        let r = Rig()
        let m = r.editor(c("a"))
        r.workspace.setExpression(c("bar"), for: "mac")
        await settle()
        #expect(!m.externalChange)
        #expect(m.expression == c("bar"))
        #expect(!m.canUndo)
        // A bar change to exactly the editor's content clears the banner.
        m.update(members(m)[0].id, condition: cond("mine"))
        r.workspace.setExpression(c("elsewhere"), for: "mac")
        await settle()
        #expect(m.externalChange)
        r.workspace.setExpression(c("mine"), for: "mac")
        await settle()
        #expect(!m.externalChange)
        #expect(!m.isEdited)
    }

    @Test func deletedLinkedFilterShowsMissing() async {
        let r = Rig()
        let n = r.library.add(name: "Noise Exclusions", expression: c("n"))
        let m = r.editor(.all([c("a"), .link(n.id)]))
        #expect(m.linkStatus(n.id) == .ok("Noise Exclusions"))
        #expect(m.text.text.contains(#""Noise Exclusions""#))
        r.workspace.delete(n.id)
        await settle()
        #expect(m.linkStatus(n.id) == .missing)
        #expect(m.text.text.contains("<missing:\(n.id.uuidString)>"))
        #expect(m.expression == .all([c("a"), .link(n.id)]))
        #expect(!m.externalChange)
        #expect(!m.isEdited)
        // A rename shows in the text too.
        let k = r.library.add(name: "Kept", expression: c("k"))
        m.add(.link(k.id), to: m.root.id)
        r.workspace.rename(k.id, to: "Renamed")
        await settle()
        #expect(m.text.text.contains(#""Renamed""#))
    }

    // MARK: - Apply, Save, links

    @Test func applySetsTheDevicesExpression() async {
        let r = Rig()
        let m = r.editor(c("a"))
        m.add(.condition(cond("b")), to: m.root.id)
        m.apply()
        #expect(r.workspace.state(for: "mac").expression == .all([c("a"), c("b")]))
        #expect(r.workspace.state(for: "mac").isEdited)
        #expect(!m.isEdited)
        await settle()
        #expect(!m.externalChange)
        // Apply is not a step.
        #expect(m.canUndo)
        m.undo()
        #expect(m.expression == c("a"))
    }

    @Test func saveOnASavedFilter() async {
        let r = Rig()
        let f = r.library.add(name: "F", expression: c("a"))
        let m = r.editor(on: f)
        m.add(.condition(cond("b")), to: m.root.id)
        #expect(m.save() == .saved)
        #expect(r.library.filter(id: f.id)?.expression == .all([c("a"), c("b")]))
        #expect(r.workspace.state(for: "mac").isEdited == false)
        #expect(!m.canUndo && !m.canRedo)
        #expect(!m.isEdited)
        await settle()
        #expect(!m.externalChange)
    }

    @Test func saveOnUntitledNeedsAName() async throws {
        let r = Rig()
        let m = r.editor(c("a"))
        m.add(.condition(cond("b")), to: m.root.id)
        #expect(m.save() == .needsName)
        #expect(r.workspace.state(for: "mac").expression == .all([c("a"), c("b")]))
        #expect(m.canUndo)
        let saved = try #require(m.saveAs(name: "New"))
        #expect(r.library.filter(id: saved.id)?.expression == .all([c("a"), c("b")]))
        #expect(r.workspace.state(for: "mac").basedOn == saved.id)
        #expect(r.workspace.displayName(for: "mac") == "New")
        #expect(!m.canUndo)
        await settle()
        #expect(!m.externalChange)
    }

    @Test func saveRefusesALoop() async {
        let r = Rig()
        let a = r.library.add(name: "A", expression: c("a"))
        let b = r.library.add(name: "B", expression: c("b"))
        let m = r.editor(on: a)
        #expect(m.add(.link(b.id), to: m.root.id) != nil)
        #expect(m.linkStatus(b.id) == .ok("B"))
        // Meanwhile another device saves B linking A.
        r.workspace.select(b.id, for: "phone")
        r.workspace.setExpression(.link(a.id), for: "phone")
        r.workspace.save(for: "phone")
        await settle()
        #expect(m.linkStatus(b.id) == .loop)
        #expect(m.loopingLinks == [b.id])
        #expect(m.save() == .refusedLoop)
        #expect(r.library.filter(id: a.id)?.expression == c("a"))
        // The preview resolves as the device would: B reaches A, so it is dropped.
        #expect(m.previewExpression == .all([c("a")]))
        #expect(m.previewExpression == r.workspace.resolvedExpression(for: "mac"))
    }

    @Test func linkChoicesExcludeLoops() {
        let r = Rig()
        let a = r.library.add(name: "A", expression: c("a"))
        let b = r.library.add(name: "B", expression: .link(a.id))
        let cc = r.library.add(name: "C", expression: .any([c("c"), .link(b.id)]))
        let d = r.library.add(name: "D", expression: c("d"))
        let m = r.editor(on: a)
        let ids = Set(m.linkChoices.map(\.id))
        #expect(ids.contains(d.id))
        #expect(ids.isDisjoint(with: [a.id, b.id, cc.id]))
        // The builder's add refuses a loop too.
        #expect(m.add(.link(b.id), to: m.root.id) == nil)
        #expect(!m.canUndo)
        // An Untitled editor may link anything.
        let untitled = r.editor(c("u"), device: "untitled")
        #expect(Set(untitled.linkChoices.map(\.id)) == Set(r.library.filters.map(\.id)))
    }

    /// The builder's "Matches saved filter [▾]" menu retargets a link in place, as one step,
    /// and refuses a missing target or a loop.
    @Test func setLinkRetargetsInPlace() {
        let r = Rig()
        let a = r.library.add(name: "A", expression: c("a"))
        let b = r.library.add(name: "B", expression: .link(a.id))
        let d = r.library.add(name: "D", expression: c("d"))
        let e = r.library.add(name: "E", expression: c("e"))
        let m = r.editor(on: a)
        let link = try! #require(m.add(.link(d.id), to: m.root.id))
        m.add(.condition(cond("x")), to: m.root.id)
        let before = m.expression

        m.setLink(link, to: e.id)
        #expect(m.expression == .all([c("a"), .link(e.id), c("x")]))
        #expect(m.node(link) != nil)
        m.undo()
        #expect(m.expression == before)
        m.redo()

        // A loop, a missing filter, the same target or a non-link change nothing.
        let steps = m.expression
        m.setLink(link, to: b.id)
        m.setLink(link, to: UUID())
        m.setLink(link, to: e.id)
        m.setLink(m.root.children[0].id, to: d.id)
        #expect(m.expression == steps)
        m.undo()
        #expect(m.expression == before)
    }

    // MARK: - Import, export, copy

    @Test func importReplacesTheTreeUndoablyAndAddsLinkedFilters() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write("""
            // name: Imported
            process == "p" AND filter == "Bundled" AND filter == "Gone"
            // filter: Bundled
            category == "c"
            """, "i.bcfilter", in: dir)
        let r = Rig()
        let m = r.editor(c("a"))
        try m.importFile(url)
        let bundled = try #require(r.library.filters.first { $0.name == "Bundled" })
        #expect(bundled.expression == .condition(FilterCondition(field: .category, match: .is, value: "c")))
        guard case .all(let xs) = m.expression, xs.count == 3, case .link(let gone) = xs[2] else {
            Issue.record("unexpected tree \(String(describing: m.expression))"); return
        }
        #expect(xs[0] == c("p"))
        #expect(xs[1] == .link(bundled.id))
        #expect(m.linkStatus(gone) == .missing)
        #expect(m.lastImportMissingLinks.map(\.link) == ["Gone"])
        #expect(m.isEdited)
        m.undo()
        #expect(m.expression == c("a"))
        m.redo()
        #expect(m.expression == .all([c("p"), .link(bundled.id), .link(gone)]))
        // A file that can't be read changes nothing.
        let bad = try write("// name: N\n(", "bad.bcfilter", in: dir)
        #expect(throws: FilterImportError.self) { try m.importFile(bad) }
        #expect(m.expression == .all([c("p"), .link(bundled.id), .link(gone)]))
    }

    /// The imported tree may reach the editor's own filter through a bundled filter that
    /// links it by name: the link is marked as a loop and Save refuses it.
    @Test func importThatLoopsIsMarkedAndSaveRefuses() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write("""
            // name: M
            process == "m" AND filter == "B"
            // filter: B
            filter == "A"
            """, "loop.bcfilter", in: dir)
        let r = Rig()
        let a = r.library.add(name: "A", expression: c("a"))
        let m = r.editor(on: a)
        try m.importFile(url)
        let b = try #require(r.library.filters.first { $0.name == "B" })
        #expect(b.expression == .link(a.id))
        #expect(m.expression == .all([c("m"), .link(b.id)]))
        #expect(m.linkStatus(b.id) == .loop)
        #expect(m.loopingLinks == [b.id])
        #expect(!m.linkChoices.contains { $0.id == b.id })
        #expect(m.save() == .refusedLoop)
        #expect(r.library.filter(id: a.id)?.expression == c("a"))
        #expect(m.previewExpression == .all([c("m")]))
    }

    @Test func exportWritesTheEditorsContent() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Rig()
        let n = r.library.add(name: "Noise", expression: c("n"))
        let f = r.library.add(name: "F", expression: c("a"))
        let m = r.editor(on: f)
        m.add(.link(n.id), to: m.root.id)
        for format in FilterFileFormat.allCases {
            let url = dir.appendingPathComponent("out.\(format.fileExtension)")
            try m.export(to: url, format: format)
            let file = try FilterFile.decode(Data(contentsOf: url), fallbackName: "x")
            #expect(file.main.name == "F")
            #expect(file.linked.map(\.name) == ["Noise"])
        }
    }

    @Test func copyAsLogPredicateLeavesOutAppOnlyParts() {
        let r = Rig()
        let n = r.library.add(name: "Noise", expression: c("n"))
        var time = FilterCondition(field: .timeOfDay, match: .between, value: "09:00")
        time.upperValue = "10:00"
        let m = r.editor(.all([c("a"), .condition(time), .link(n.id)]))
        let copied = m.copyAsLogPredicate()
        #expect(copied.removed == 2)
        #expect(copied.text == PredicateWriter.write(c("a"), nameForLink: { _ in nil }).text)
    }

    @Test func windowTitleShowsNameAndEdited() {
        let r = Rig()
        let f = r.library.add(name: "DDG Errors", expression: c("a"))
        let m = r.editor(on: f)
        #expect(m.title == "Edit Filter — DDG Errors")
        m.add(.condition(cond("b")), to: m.root.id)
        #expect(m.title == "Edit Filter — DDG Errors (Edited)")
        let u = r.editor(device: "u")
        #expect(u.title == "Edit Filter — Untitled")
    }
}

extension FilterEditorModelTests {
    /// Alternating Any of / All of groups, `levels` deep, around `leaf`: `leaf`'s depth plus
    /// `levels` tree levels.
    private func nestedGroups(_ levels: Int, around leaf: FilterExpression) -> FilterExpression {
        var e = leaf
        for i in 0..<levels { e = i.isMultiple(of: 2) ? .any([c("p\(i)"), e]) : .all([c("q\(i)"), e]) }
        return e
    }

    /// The innermost group's id, following the last member down.
    private func innermostGroup(_ m: FilterEditorModel) -> EditorNode {
        var node = m.root
        while let last = node.children.last(where: \.isGroup) { node = last }
        return node
    }

    /// The builder can't nest past FilterFile.maxDepth: Wrap in group, ＋ Group, a kind that
    /// adds a level and a move into a deep group are refused, and say so beforehand.
    @Test func builderRefusesNestingPastTheDepthCap() {
        let r = Rig()
        // The root group plus 30 levels: the innermost condition is at depth 32.
        let m = r.editor(nestedGroups(31, around: c("x")))
        #expect(m.expression.map(FilterFile.depth) == FilterFile.maxDepth)
        let inner = innermostGroup(m)
        let x = inner.children.last!.id
        let before = m.expression

        #expect(!m.canWrap(x))
        #expect(m.wrapInGroup(x) == nil)
        #expect(!m.canAddGroup(to: inner.id))
        #expect(m.add(.group(.allOf), to: inner.id) == nil)
        // None of adds a level (`.not(.any)`).
        m.setGroupKind(inner.id, .noneOf)
        #expect(m.expression == before)
        #expect(!m.canUndo)

        // Conditions still go in, and a shallower node can still be wrapped.
        #expect(m.add(.condition(cond("y")), to: inner.id) != nil)
        let top = members(m)[0].id
        #expect(m.canWrap(top))
        #expect(m.wrapInGroup(top) != nil)
        #expect(m.canAddGroup(to: m.root.id))

        // Moving a group into the innermost one would push its member past the cap.
        let g = m.add(.group(.anyOf), to: m.root.id)!
        m.add(.condition(cond("z")), to: g)
        let count = m.expression
        m.move(g, to: inner.id, index: 0)
        #expect(m.expression == count)
    }
}
