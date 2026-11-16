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
    @ObservationIgnored public var onExpressionChange:
        (@MainActor (_ deviceID: String, _ expression: FilterExpression?) -> Void)?

    private var states: [String: DeviceFilterState]
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
    }

    public func state(for deviceID: String) -> DeviceFilterState {
        states[deviceID] ?? .empty
    }

    public func displayName(for deviceID: String) -> String {
        guard let base = state(for: deviceID).basedOn, let filter = library.filter(id: base)
        else { return "Untitled" }
        return filter.name
    }

    public func setExpression(_ expression: FilterExpression?, for deviceID: String) {
        var s = state(for: deviceID)
        s.expression = expression
        s.isEdited = true
        apply(s, for: deviceID)
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

    /// Writes the device's expression into the filter it is based on. Does nothing for an
    /// Untitled device (Save As is the action there) or one whose filter is gone.
    public func save(for deviceID: String) {
        let s = state(for: deviceID)
        guard let base = s.basedOn, library.filter(id: base) != nil else { return }
        library.update(id: base, expression: s.expression)
        var saved = s
        saved.isEdited = false
        states[deviceID] = saved
        for (other, var o) in states where other != deviceID && o.basedOn == base && !o.isEdited {
            guard o.expression != s.expression else { continue }
            o.expression = s.expression
            states[other] = o
            onExpressionChange?(other, o.expression)
        }
        persist()
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

    public func rename(_ filterID: UUID, to name: String) {
        library.rename(id: filterID, to: name)
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

    public func delete(_ filterID: UUID) {
        library.delete(id: filterID)
        for (id, var s) in states where s.basedOn == filterID {
            s.basedOn = nil
            s.isEdited = true
            states[id] = s
        }
        persist()
    }

    // MARK: - Private

    private func apply(_ new: DeviceFilterState, for deviceID: String) {
        let old = state(for: deviceID)
        states[deviceID] = new
        persist()
        if old.expression != new.expression { onExpressionChange?(deviceID, new.expression) }
    }

    private func persist() { persistence.save(states) }
}
