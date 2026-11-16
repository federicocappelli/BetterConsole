import BCModel
import Foundation

extension LogEntry {
    /// Last path component of `senderImagePath` (what the Library field reads).
    var libraryName: String? {
        guard let path = senderImagePath else { return nil }
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// Distinct process, subsystem, category and library values seen in a device's logs, used
/// to suggest filter values. Past `capPerField` new values are ignored.
public struct SeenValues: Sendable {
    public static let capPerField = 5_000

    private var sets: [FilterField: Set<String>] = [:]

    public init() {}

    public mutating func insert(_ entry: LogEntry) {
        add(entry.process, to: .process)
        add(entry.subsystem, to: .subsystem)
        add(entry.category, to: .category)
        add(entry.libraryName, to: .library)
    }

    /// Sorted alphabetically; empty for fields that are not tracked.
    public func values(for field: FilterField) -> [String] {
        (sets[field] ?? []).sorted()
    }

    private mutating func add(_ value: String?, to field: FilterField) {
        guard let value, !value.isEmpty else { return }
        let count = sets[field]?.count ?? 0
        guard count < Self.capPerField else { return }
        sets[field, default: []].insert(value)
    }
}
