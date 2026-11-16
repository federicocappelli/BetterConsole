import Foundation
import Observation

/// The model behind the filter editor window (ES §8, §9, §13): a copy of a device's filter as
/// a tree, edited in the builder or as predicate text, with its own undo history.
@MainActor @Observable
public final class FilterEditorModel {
    public enum NewNodeKind: Hashable, Sendable {
        case condition(FilterCondition)
        case group(GroupKind)
        case link(UUID)
    }

    public enum SaveOutcome: Equatable, Sendable {
        case saved
        /// The device is Untitled: the edit was applied; ask for a name and call `saveAs`.
        case needsName
        /// The filter links one that links back to it (ES §9's defensive check). The edit was
        /// applied, the saved filter is unchanged.
        case refusedLoop
        /// The text has an error: nothing was applied or saved (ES §13.3).
        case textHasError
        /// The filter is nested more than `FilterFile.maxDepth` levels (defensive: the editor
        /// never makes such a tree). Nothing was saved.
        case tooDeep
    }

    public enum EditorError: Error, Equatable {
        /// ES §13.3: "Fix the error in the predicate first".
        case textHasError
    }

    /// What a link node points at.
    public enum LinkStatus: Equatable, Sendable {
        case ok(String)
        /// The filter was deleted (ES §9): red "Missing filter", ignored at evaluation.
        case missing
        /// Linking it from this filter would make a loop (ES §13.4).
        case loop
    }

    /// What "＋ Condition" adds.
    public static let newCondition = FilterCondition(field: .message, match: .contains, value: "")

    public let deviceID: String
    public private(set) var root: EditorNode
    public private(set) var text: PredicateText
    public private(set) var textError: PredicateParseError?
    /// The device's filter changed elsewhere while this editor had changes of its own.
    public private(set) var externalChange = false
    /// Links the last Import couldn't resolve (ES §7.2).
    public private(set) var lastImportMissingLinks: [(filter: String, link: String)] = []

    private var undoStack: [EditorNode] = []
    private var redoStack: [EditorNode] = []

    @ObservationIgnored private let workspace: FilterWorkspace
    @ObservationIgnored private let library: FilterLibrary
    /// Each node's path in `expression`, matching `text.nodeRanges`.
    @ObservationIgnored private var paths: [UUID: NodePath] = [:]
    /// The device's expression the editor last saw, to tell when it changes elsewhere.
    @ObservationIgnored private var baseline: FilterExpression?
    /// Between a `textDidChange` and `endTextEditing`.
    @ObservationIgnored private var textSessionOpen = false
    /// The condition and value field being typed in, while its changes share one undo step.
    @ObservationIgnored private var typingRun: (id: UUID, field: ValueField)?

    private enum ValueField {
        case value, key, upperValue

        /// The one value field that differs, when nothing else does.
        static func onlyChange(from old: FilterCondition, to new: FilterCondition) -> ValueField? {
            guard old.field == new.field, old.match == new.match, old.isEnabled == new.isEnabled
            else { return nil }
            let changed: [ValueField] = [
                old.value != new.value ? .value : nil,
                old.key != new.key ? .key : nil,
                old.upperValue != new.upperValue ? .upperValue : nil,
            ].compactMap { $0 }
            return changed.count == 1 ? changed[0] : nil
        }
    }

    public init(deviceID: String, workspace: FilterWorkspace, library: FilterLibrary) {
        self.deviceID = deviceID
        self.workspace = workspace
        self.library = library
        let current = workspace.state(for: deviceID).expression
        baseline = current
        root = EditorNode(root: current)
        text = PredicateText(text: "", appOnlyRanges: [], nodeRanges: [:])
        regenerateText()
        observeWorkspace()
    }

    // MARK: - State

    public var expression: FilterExpression? { root.rootExpression }

    /// The editor's tree differs from what the device currently uses.
    public var isEdited: Bool { expression != Self.asEdited(workspace.state(for: deviceID).expression) }

    /// Work the window must not lose without asking: an edited tree, or text being typed that
    /// has an error or isn't yet the canonical layout. Cancel and close prompt on it, and a
    /// change to the device's filter shows the banner rather than replacing it.
    public var hasUnsavedChanges: Bool { isEdited || textIsDirty }

    /// Apply, Save and Export need text without an error (ES §13.3).
    public var canApply: Bool { textError == nil }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// "Edit Filter — <name>", with "(Edited)" when the content differs from the device's.
    public var title: String {
        "Edit Filter — \(workspace.displayName(for: deviceID))" + (isEdited ? " (Edited)" : "")
    }

    /// The tree to count in the live preview, resolved as the device's session would resolve
    /// it (ES §8.5).
    public var previewExpression: FilterExpression? {
        workspace.resolve(expression, forDevice: deviceID)
    }

    public func node(_ id: UUID) -> EditorNode? { root.find(id) }

    /// The group holding `id` and its index there; nil for the root.
    public func location(of id: UUID) -> (parent: UUID, index: Int)? { root.location(of: id) }

    // MARK: - Links

    /// Saved filters the builder's menu offers: none that would make a loop (ES §13.4).
    public var linkChoices: [SavedFilter] {
        library.filters.filter { workspace.canLink($0.id, forDevice: deviceID) }
    }

    public func linkStatus(_ target: UUID) -> LinkStatus {
        guard let filter = library.filter(id: target) else { return .missing }
        return workspace.canLink(target, forDevice: deviceID) ? .ok(filter.name) : .loop
    }

    /// Links in the tree that would make a loop, for instance through a filter an Import
    /// added that links this one by name. Save refuses while there are any.
    public var loopingLinks: Set<UUID> {
        Set(FilterLinks.links(in: expression).filter {
            library.filter(id: $0) != nil && !workspace.canLink($0, forDevice: deviceID)
        })
    }

    // MARK: - Edits

    /// Adds a node at the end of the group `groupID`, returning its id. Nothing happens (nil)
    /// when `groupID` is not a group, the link would make a loop, or the tree would be nested
    /// past `FilterFile.maxDepth` (a group must have room for a member).
    @discardableResult
    public func add(_ kind: NewNodeKind, to groupID: UUID) -> UUID? {
        guard node(groupID)?.isGroup == true else { return nil }
        let new: EditorNode
        switch kind {
        case .condition(let c): new = EditorNode(kind: .condition(c))
        case .group(let k):
            guard canAddGroup(to: groupID) else { return nil }
            new = EditorNode(kind: .group(k, []))
        case .link(let target):
            guard library.filter(id: target) != nil, workspace.canLink(target, forDevice: deviceID)
            else { return nil }
            new = EditorNode(kind: .link(target))
        }
        guard edit({ $0.modify(groupID) { $0.modifyMembers { $0.append(new) } } }) else { return nil }
        return new.id
    }

    /// Changes a condition. With `coalescing` (typing in a value field), consecutive changes
    /// to the same value field of the same condition are one undo step (ES §8.4, R16); any
    /// other change, undo, redo, a text edit or `endCoalescing` starts a new one. A run typed
    /// back to where it started leaves no step.
    public func update(_ id: UUID, condition: FilterCondition, coalescing: Bool = false) {
        func change(_ tree: inout EditorNode) {
            tree.modify(id) { node in
                if case .condition = node.kind { node.kind = .condition(condition) }
            }
        }
        guard coalescing, case .condition(let old)? = node(id)?.kind,
              let field = ValueField.onlyChange(from: old, to: condition)
        else {
            edit(change)
            return
        }
        guard let run = typingRun, run.id == id, run.field == field, !undoStack.isEmpty else {
            let before = root
            edit(change)
            if root != before { typingRun = (id, field) }
            return
        }
        var new = root
        change(&new)
        guard new != root else { return }
        redoStack.removeAll()
        root = new
        let isBackToStart = new == undoStack.last
        if isBackToStart { undoStack.removeLast() }
        treeDidChange()
        if !isBackToStart { typingRun = run }
    }

    /// The value field being typed in lost focus or was submitted: the next change is a new
    /// undo step.
    public func endCoalescing() { typingRun = nil }

    /// Points the link `id` at another saved filter, in place (the builder's "Matches saved
    /// filter" menu). Nothing happens when the target is missing or would make a loop.
    public func setLink(_ id: UUID, to target: UUID) {
        guard library.filter(id: target) != nil, workspace.canLink(target, forDevice: deviceID)
        else { return }
        edit {
            $0.modify(id) { node in
                if case .link = node.kind { node.kind = .link(target) }
            }
        }
    }

    public func setGroupKind(_ id: UUID, _ kind: GroupKind) {
        edit {
            $0.modify(id) { node in
                if case .group(_, let xs) = node.kind { node.kind = .group(kind, xs) }
            }
        }
    }

    /// Conditions only; links (R7) and groups can't be switched off.
    public func setEnabled(_ id: UUID, _ on: Bool) {
        edit {
            $0.modify(id) { node in
                if case .condition(var c) = node.kind {
                    c.isEnabled = on
                    node.kind = .condition(c)
                }
            }
        }
    }

    /// Inserts a copy (with new ids) right after the node. Not the root.
    public func duplicate(_ id: UUID) {
        guard let (parent, index) = location(of: id), let original = node(id) else { return }
        edit { $0.modify(parent) { $0.modifyMembers { $0.insert(original.withFreshIDs(), at: index + 1) } } }
    }

    /// Not the root.
    public func delete(_ id: UUID) {
        guard let (parent, index) = location(of: id) else { return }
        edit { $0.modify(parent) { $0.modifyMembers { $0.remove(at: index) } } }
    }

    /// Puts the node alone in a new All of group in its place, returning the group's id. The
    /// group is kept as made (R5). Not the root, and nil when the tree would be nested past
    /// `FilterFile.maxDepth`.
    @discardableResult
    public func wrapInGroup(_ id: UUID) -> UUID? {
        guard let (parent, index) = location(of: id), let original = node(id) else { return nil }
        let group = EditorNode(kind: .group(.allOf, [original]))
        guard edit({ $0.modify(parent) { $0.modifyMembers { $0[index] = group } } }) else { return nil }
        return group.id
    }

    /// Whether Wrap in group keeps the tree within `FilterFile.maxDepth`.
    public func canWrap(_ id: UUID) -> Bool {
        guard let (parent, index) = location(of: id), let original = node(id) else { return false }
        return fits { $0.modify(parent) { $0.modifyMembers { $0[index] = EditorNode(kind: .group(.allOf, [original])) } } }
    }

    /// Whether ＋ Group can add a group to `groupID` that still has room for a condition
    /// within `FilterFile.maxDepth`.
    public func canAddGroup(to groupID: UUID) -> Bool {
        guard node(groupID)?.isGroup == true else { return false }
        let probe = EditorNode(kind: .group(.allOf, [EditorNode(kind: .condition(Self.newCondition))]))
        return fits { $0.modify(groupID) { $0.modifyMembers { $0.append(probe) } } }
    }

    /// Replaces a group with its members. Not the root.
    public func ungroup(_ id: UUID) {
        guard let (parent, index) = location(of: id), let group = node(id), group.isGroup
        else { return }
        edit { $0.modify(parent) { $0.modifyMembers { $0.replaceSubrange(index...index, with: group.children) } } }
    }

    /// Move Up (-1) / Down (+1) within the node's group; nothing when that leaves the group.
    public func move(_ id: UUID, by offset: Int) {
        guard let (parent, index) = location(of: id), let group = node(parent) else { return }
        let target = index + offset
        guard offset != 0, group.children.indices.contains(target) else { return }
        edit { $0.modify(parent) { $0.modifyMembers { $0.insert($0.remove(at: index), at: target) } } }
    }

    /// Moves the node into the group `groupID` at `index`, a drop position in that group's
    /// members before the move (clamped). Not the root, and not into the node itself.
    public func move(_ id: UUID, to groupID: UUID, index: Int) {
        guard let (parent, from) = location(of: id), let moving = node(id),
              moving.find(groupID) == nil, let destination = node(groupID), destination.isGroup
        else { return }
        var to = min(max(index, 0), destination.children.count)
        if parent == groupID, from < to { to -= 1 }
        edit { tree in
            tree.modify(parent) { $0.modifyMembers { $0.remove(at: from) } }
            tree.modify(groupID) { $0.modifyMembers { $0.insert(moving, at: to) } }
        }
    }

    // MARK: - Undo

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(root)
        root = previous
        treeDidChange()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(root)
        root = next
        treeDidChange()
    }

    // MARK: - Text

    /// Reads the text as typed; the window calls this after each pause in typing. Valid text
    /// that changes the tree replaces it as one undo step (ES §8.4, R12); text that means the
    /// current tree records nothing. The text is left as typed, with its ranges mapped to the
    /// rows (R13). Invalid text sets `textError` and keeps the tree.
    public func textDidChange(_ newText: String) {
        textSessionOpen = true
        typingRun = nil
        switch PredicateParser.parseWithRanges(newText, linkForName: linkLookup) {
        case .failure(let error):
            textError = error
            text = PredicateText(text: newText, appOnlyRanges: [], nodeRanges: [:])
            paths = [:]
        case .success(let parsed):
            textError = nil
            // Text that means the same tree keeps the tree (and its builder-made groups).
            let new = EditorNode(root: parsed.expression)
            if new.rootExpression != expression {
                undoStack.append(root)
                redoStack.removeAll()
                root = new.reusingIDs(of: root)
            }
            var nodePaths: [UUID: NodePath] = [:]
            let current = root.rootExpression(paths: &nodePaths)
            text = parsed.text
            // A kept builder-made group can make the tree differ from the text's.
            paths = current == parsed.expression ? nodePaths : [:]
        }
    }

    /// Focus left the text: valid text is rewritten in the canonical layout.
    public func endTextEditing() {
        textSessionOpen = false
        if textError == nil { regenerateText() }
    }

    /// The text written for a node, when the text is the canonical layout.
    public func textRange(for id: UUID) -> Range<String.Index>? {
        paths[id].flatMap { text.nodeRanges[$0] }
    }

    /// The innermost node whose text contains `index`.
    public func nodeID(at index: String.Index) -> UUID? {
        var best: (id: UUID, length: Int, isGroup: Bool)?
        for (id, path) in paths {
            guard let range = text.nodeRanges[path],
                  range.contains(index) || range.lowerBound == index
            else { continue }
            let length = text.text.distance(from: range.lowerBound, to: range.upperBound)
            let isGroup = node(id)?.isGroup ?? false
            if best == nil || length < best!.length || (length == best!.length && best!.isGroup && !isGroup) {
                best = (id, length, isGroup)
            }
        }
        return best?.id
    }

    // MARK: - The device's filter

    /// Replaces the tree with the device's current filter (an undo step) and clears the
    /// banner.
    public func reloadFromDevice() {
        let current = workspace.state(for: deviceID).expression
        baseline = current
        externalChange = false
        replaceTree(with: EditorNode(root: current))
    }

    /// Keeps the editor's version; the banner goes away.
    public func keepMine() { externalChange = false }

    /// Sets the device's filter to the editor's tree. Not an undo step.
    public func apply() {
        guard canApply else { return }
        externalChange = false
        guard isEdited else { return }
        let e = expression
        if workspace.setExpression(e, for: deviceID) { baseline = e }
    }

    /// Applies, then saves into the device's saved filter (ES §8.6). The undo history resets
    /// after a save.
    public func save() -> SaveOutcome {
        guard canApply else { return .textHasError }
        apply()
        switch workspace.save(for: deviceID) {
        case .saved:
            resetHistory()
            return .saved
        case .noBaseFilter: return .needsName
        case .refusedLoop: return .refusedLoop
        case .tooDeep: return .tooDeep
        }
    }

    /// Applies, then saves as a new filter the device switches to. Nil while the text has an
    /// error.
    @discardableResult
    public func saveAs(name: String) -> SavedFilter? {
        guard canApply else { return nil }
        apply()
        let filter = workspace.saveAs(name: name, for: deviceID)
        baseline = workspace.state(for: deviceID).expression
        resetHistory()
        return filter
    }

    // MARK: - Files

    /// Replaces the tree with the file's filter (an undo step); the filters it bundles are
    /// added to the library. Unresolved links are in `lastImportMissingLinks`; links that
    /// would make a loop show as `.loop` and Save refuses them.
    public func importFile(_ url: URL) throws {
        let result = try library.decodeForEditor(url)
        lastImportMissingLinks = result.missingLinks
        replaceTree(with: EditorNode(root: result.expression))
    }

    /// Writes the editor's content under the device's filter name, with the filters it links.
    public func export(to url: URL, format: FilterFileFormat) throws {
        guard canApply else { throw EditorError.textHasError }
        try library.export(
            expression: expression, name: workspace.displayName(for: deviceID), to: url, format: format)
    }

    /// The text `log stream --predicate` accepts, and how many conditions and links were left
    /// out (ES §6.5).
    public func copyAsLogPredicate() -> (text: String, removed: Int) {
        PredicateWriter.logPredicate(expression, nameForLink: { [library] in library.filter(id: $0)?.name })
    }

    // MARK: - Private

    /// The device's expression as the editor would hold it, for comparing.
    private static func asEdited(_ e: FilterExpression?) -> FilterExpression? {
        EditorNode(root: e).rootExpression
    }

    /// One undo step, when `change` changes anything and doesn't nest the tree past
    /// `FilterFile.maxDepth` (a change to a tree already past it may keep or reduce its depth).
    /// False when nothing changed.
    @discardableResult
    private func edit(_ change: (inout EditorNode) -> Void) -> Bool {
        var new = root
        change(&new)
        guard new != root, Self.depth(new) <= max(FilterFile.maxDepth, Self.depth(root)) else { return false }
        undoStack.append(root)
        redoStack.removeAll()
        root = new
        treeDidChange()
        return true
    }

    /// Whether `change` keeps the tree within `FilterFile.maxDepth`.
    private func fits(_ change: (inout EditorNode) -> Void) -> Bool {
        var new = root
        change(&new)
        return Self.depth(new) <= FilterFile.maxDepth
    }

    /// The tree's depth as files count it (an empty tree is 0).
    private static func depth(_ tree: EditorNode) -> Int {
        tree.rootExpression.map(FilterFile.depth) ?? 0
    }

    private func replaceTree(with new: EditorNode) {
        edit { $0 = new.reusingIDs(of: $0) }
        // An identical tree is not a step, but the text is still rewritten.
        treeDidChange()
    }

    private func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// A tree change from the builder, undo, Import or Reload: the text is rewritten.
    private func treeDidChange() {
        typingRun = nil
        textSessionOpen = false
        textError = nil
        regenerateText()
    }

    private func regenerateText() {
        let canonical = canonicalText()
        paths = canonical.paths
        if canonical.text.text != text.text || canonical.text.nodeRanges != text.nodeRanges {
            text = canonical.text
        }
    }

    private func canonicalText() -> (text: PredicateText, paths: [UUID: NodePath]) {
        var paths: [UUID: NodePath] = [:]
        let e = root.rootExpression(paths: &paths)
        let written = PredicateWriter.write(e, nameForLink: { [library] in library.filter(id: $0)?.name })
        return (written, paths)
    }

    /// The text shown differs from what the tree would write: it has an error, or it is being
    /// typed in another layout.
    private var textIsDirty: Bool {
        textError != nil || text.text != canonicalText().text.text
    }

    /// Names resolve exact case first; a filter that would make a loop is refused (ES §13.4).
    private func linkLookup(_ name: String) -> LinkLookup {
        let filters = library.filters
        guard let filter = filters.first(where: { $0.name == name })
            ?? filters.first(where: { $0.name.lowercased() == name.lowercased() })
        else { return .notFound }
        return workspace.canLink(filter.id, forDevice: deviceID) ? .found(filter.id) : .wouldLoop
    }

    /// Watches the device's state and the library; told after each change, on the main actor.
    private func observeWorkspace() {
        withObservationTracking {
            _ = workspace.state(for: deviceID)
            _ = library.filters
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.workspaceDidChange() }
        }
    }

    /// The device's filter changed elsewhere. An editor without unsaved changes follows it;
    /// following is not an undo step and leaves the undo history as it was, so Undo then
    /// returns to the tree before the last step. One with unsaved changes (including text
    /// being typed) shows the banner, unless the device now has exactly the editor's content.
    /// Link names may have changed too, so the text is rewritten unless the user is typing.
    private func workspaceDidChange() {
        observeWorkspace()
        let current = workspace.state(for: deviceID).expression
        if current != baseline {
            let hadChanges = expression != Self.asEdited(baseline) || textIsDirty
            baseline = current
            if !hadChanges {
                root = EditorNode(root: current).reusingIDs(of: root)
                externalChange = false
                treeDidChange()
            } else {
                externalChange = hasUnsavedChanges
            }
        }
        if !textSessionOpen, textError == nil { regenerateText() }
    }
}
