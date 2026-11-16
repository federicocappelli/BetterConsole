import BCModel
import Foundation

public struct QuickFilterItem: Hashable, Sendable {
    public var condition: FilterCondition
    /// The value as shown in the right-click menu (middle-truncated when long).
    public var menuValue: String
}

public enum QuickFilterItems {
    public static let maxMenuValueLength = 60

    /// One item per value the row has, in Console.app's order.
    public static func items(for entry: LogEntry) -> [QuickFilterItem] {
        let candidates: [(FilterField, String?)] = [
            (.process, entry.process),
            (.pid, entry.pid.map { String($0) }),
            (.library, entry.libraryName),
            (.thread, entry.threadID.map { "0x" + String($0, radix: 16) }),
            (.subsystem, entry.subsystem),
            (.category, entry.category),
            (.type, entry.level.rawValue.lowercased()),
            (.activity, entry.activityID.map { String($0) }),
        ]
        return candidates.compactMap { field, value in
            guard let value, !value.isEmpty else { return nil }
            return QuickFilterItem(
                condition: FilterCondition(field: field, match: .is, value: value),
                menuValue: truncated(value))
        }
    }

    private static func truncated(_ value: String) -> String {
        guard value.count > maxMenuValueLength else { return value }
        let keep = maxMenuValueLength - 1
        let head = keep - keep / 2
        return String(value.prefix(head)) + "…" + String(value.suffix(keep / 2))
    }
}
