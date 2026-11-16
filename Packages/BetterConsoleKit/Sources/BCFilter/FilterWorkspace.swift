import Foundation
import Observation

public struct DeviceFilterState: Codable, Hashable, Sendable {
    public var basedOn: UUID?
    public var expression: FilterExpression?
    public var isEdited: Bool

    public init(basedOn: UUID? = nil, expression: FilterExpression? = nil, isEdited: Bool = false) {
        self.basedOn = basedOn
        self.expression = expression
        self.isEdited = isEdited
    }

    public static let empty = DeviceFilterState()
}

public protocol DeviceFilterPersistence {
    func load() -> [String: DeviceFilterState]
    func save(_ states: [String: DeviceFilterState])
}

public struct UserDefaultsDeviceFilterPersistence: DeviceFilterPersistence {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "deviceFilters") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: DeviceFilterState] {
        guard let data = defaults.data(forKey: key),
              let states = try? JSONDecoder().decode([String: DeviceFilterState].self, from: data)
        else { return [:] }
        return states
    }

    public func save(_ states: [String: DeviceFilterState]) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor @Observable
public final class FilterWorkspace {
    /// Called with a device's **resolved** expression (links replaced by the linked filters'
    /// current trees, ES §13.7) whenever it changes, at most once per device per action.
    @ObservationIgnored public var onExpressionChange:
        (@MainActor (_ deviceID: String, _ expression: FilterExpression?) -> Void)?

    private var states: [String: DeviceFilterState]
    /// The resolved tree last reported per device (absent: nil), to tell which devices an
    /// action changed.
    @ObservationIgnored private var resolved: [String: FilterExpression] = [:]
    @ObservationIgnored private let library: FilterLibrary
    @ObservationIgnored private let persistence: any DeviceFilterPersistence

    public init(library: FilterLibrary, persistence: any DeviceFilterPersistence) {
        self.library = library
        self.persistence = persistence
        var restored = persistence.load()
        for (id, var state) in restored {
            if let base = state.basedOn {
                if let filter = library.filter(id: base) {
                    if !state.isEdited { state.expression = filter.expression }
                } else {
                    state.basedOn = nil
                    state.isEdited = state.expression != nil
                }
                restored[id] = state
            }
        }
        states = restored
        for deviceID in states.keys { resolved[deviceID] = resolvedExpression(for: deviceID) }
    }

    public func state(for deviceID: String) -> DeviceFilterState {
        states[deviceID] ?? .empty
    }

    public func displayName(for deviceID: String) -> String {
        guard let base = state(for: deviceID).basedOn, let filter = library.filter(id: base)
        else { return "Untitled" }
        return filter.name
    }

    /// Sets the device's expression; false (and nothing changes) when the tree is nested more
    /// than `FilterFile.maxDepth` levels, which the editor and the parser never produce: such
    /// a tree couldn't be persisted or exported reliably.
    @discardableResult
    public func setExpression(_ expression: FilterExpression?, for deviceID: String) -> Bool {
        guard Self.fitsDepthCap(expression) else { return false }
        var s = state(for: deviceID)
        s.expression = expression
        s.isEdited = true
        apply(s, for: deviceID)
        return true
    }

    /// Within `FilterFile.maxDepth`, counted as files count it.
    public static func fitsDepthCap(_ expression: FilterExpression?) -> Bool {
        expression.map(FilterFile.depth).map { $0 <= FilterFile.maxDepth } ?? true
    }

    public func select(_ filterID: UUID?, for deviceID: String) {
        if let filterID, let filter = library.filter(id: filterID) {
            apply(
                DeviceFilterState(basedOn: filterID, expression: filter.expression, isEdited: false),
                for: deviceID)
        } else {
            apply(.empty, for: deviceID)
        }
    }

    /// What `save(for:)` did.
    public enum SaveResult: Equatable, Sendable {
        case saved
        /// The device is Untitled, or its filter is gone: Save As is the action there.
        case noBaseFilter
        /// The expression links a filter that links back to it (ES §9's defensive check).
        case refusedLoop
        /// The expression is nested more than `FilterFile.maxDepth` levels (a defensive check:
        /// `setExpression` already refuses such trees).
        case tooDeep
    }

    /// Writes the device's expression into the filter it is based on. Does nothing for an
    /// Untitled device (Save As is the action there), one whose filter is gone, when the
    /// expression links a filter that links back to it (a loop, ES §9's defensive check), or
    /// when it is nested past the depth cap.
    @discardableResult
    public func save(for deviceID: String) -> SaveResult {
        let s = state(for: deviceID)
        guard let base = s.basedOn, library.filter(id: base) != nil else { return .noBaseFilter }
        guard Self.fitsDepthCap(s.expression) else { return .tooDeep }
        let filters = library.filters
        guard !FilterLinks.links(in: s.expression).contains(where: {
            FilterLinks.wouldLoop(linking: $0, from: base, in: filters)
        }) else { return .refusedLoop }
        library.update(id: base, expression: s.expression)
        var saved = s
        saved.isEdited = false
        states[deviceID] = saved
        for (other, var o) in states where other != deviceID && o.basedOn == base && !o.isEdited {
            o.expression = s.expression
            states[other] = o
        }
        persist()
        publishResolvedChanges()
        return .saved
    }

    @discardableResult
    public func saveAs(name: String, for deviceID: String) -> SavedFilter {
        var s = state(for: deviceID)
        let filter = library.add(name: name, expression: s.expression)
        s.basedOn = filter.id
        s.isEdited = false
        apply(s, for: deviceID)
        return filter
    }

    public func discard(for deviceID: String) {
        var s = state(for: deviceID)
        s.expression = s.basedOn.flatMap { library.filter(id: $0) }?.expression
        s.isEdited = false
        apply(s, for: deviceID)
    }

    /// Links are stored by id, so they survive a rename.
    public func rename(_ filterID: UUID, to name: String) {
        library.rename(id: filterID, to: name)
        publishResolvedChanges()
    }

    @discardableResult
    public func duplicate(for deviceID: String) -> SavedFilter {
        var s = state(for: deviceID)
        let saved = s.basedOn.flatMap { library.filter(id: $0) }
        let copy = library.add(
            name: "\(displayName(for: deviceID)) copy", expression: saved?.expression)
        s.basedOn = copy.id
        apply(s, for: deviceID)
        return copy
    }

    /// Links to the deleted filter stay where they are, as missing links that resolve to
    /// nothing (ES §9); devices whose resolved tree loses them are told.
    public func delete(_ filterID: UUID) {
        library.delete(id: filterID)
        for (id, var s) in states where s.basedOn == filterID {
            s.basedOn = nil
            s.isEdited = true
            states[id] = s
        }
        persist()
        publishResolvedChanges()
    }

    // MARK: - Links

    /// The device's expression with links replaced by the linked filters' current trees,
    /// recursively. Missing links and loops are removed. A link to the device's own filter
    /// counts as a loop (ES §13.4).
    public func resolvedExpression(for deviceID: String) -> FilterExpression? {
        resolve(state(for: deviceID).expression, forDevice: deviceID)
    }

    /// `expression` resolved as if it were the device's own: the device's saved filter counts
    /// as already on the link path, so the editor's preview drops what the device's session
    /// would drop.
    public func resolve(_ expression: FilterExpression?, forDevice deviceID: String) -> FilterExpression? {
        var path = Set<UUID>()
        if let base = state(for: deviceID).basedOn { path.insert(base) }
        return expression.flatMap { resolve($0, path: &path) }
    }

    /// `expression` with links resolved as in `resolvedExpression(for:)`, for a tree that
    /// belongs to no saved filter (the editor's preview).
    public func resolve(_ expression: FilterExpression?) -> FilterExpression? {
        var path = Set<UUID>()
        return expression.flatMap { resolve($0, path: &path) }
    }

    /// Names of the saved filters that link `filterID` directly or indirectly, sorted.
    public func dependentsNames(of filterID: UUID) -> [String] {
        let ids = FilterLinks.dependents(of: filterID, in: library.filters)
        return library.filters.filter { ids.contains($0.id) }.map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Names of the saved filters that link `filterID` themselves, sorted, for the delete
    /// prompt: those are the links that stop matching (ES §9).
    public func directDependentsNames(of filterID: UUID) -> [String] {
        let ids = FilterLinks.directDependents(of: filterID, in: library.filters)
        return library.filters.filter { ids.contains($0.id) }.map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Whether the device's filter may link `target`: not its own saved filter, nor one that
    /// links it directly or indirectly. An Untitled device may link anything (ES §13.4).
    public func canLink(_ target: UUID, forDevice deviceID: String) -> Bool {
        !FilterLinks.wouldLoop(
            linking: target, from: state(for: deviceID).basedOn, in: library.filters)
    }

    // MARK: - Private

    private func apply(_ new: DeviceFilterState, for deviceID: String) {
        states[deviceID] = new
        persist()
        publishResolvedChanges()
    }

    /// Recomputes every device's resolved tree and reports the ones that changed, once each,
    /// in device order. Every action ends here, so a save or delete reaches devices that
    /// only link the filter it touched.
    private func publishResolvedChanges() {
        var changed: [(String, FilterExpression?)] = []
        for deviceID in states.keys.sorted() {
            let new = resolvedExpression(for: deviceID)
            guard resolved[deviceID] != new else { continue }
            resolved[deviceID] = new
            changed.append((deviceID, new))
        }
        for (deviceID, expression) in changed { onExpressionChange?(deviceID, expression) }
    }

    /// `path` holds the filters being resolved above this node; linking one of them again is
    /// a loop. A removed node leaves its group; a `.not` of a removed node is removed too,
    /// matching `CompiledFilter`.
    private func resolve(_ e: FilterExpression, path: inout Set<UUID>) -> FilterExpression? {
        switch e {
        case .condition: return e
        case .all(let xs): return .all(xs.compactMap { resolve($0, path: &path) })
        case .any(let xs): return .any(xs.compactMap { resolve($0, path: &path) })
        case .not(let x): return resolve(x, path: &path).map(FilterExpression.not)
        case .link(let id):
            guard !path.contains(id), let linked = library.filter(id: id)?.expression
            else { return nil }
            path.insert(id)
            defer { path.remove(id) }
            return resolve(linked, path: &path)
        }
    }

    private func persist() { persistence.save(states) }
}
