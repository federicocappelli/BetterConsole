import Foundation
import BCModel

/// A bounded, in-memory collection of log entries. Index 0 is the oldest entry.
@MainActor
public protocol LogStore: AnyObject {
    var count: Int { get }
    /// Sum of `LogEntry.estimatedBytes` over all stored entries.
    var estimatedBytes: Int { get }
    var oldestDate: Date? { get }
    /// Entries removed since the store was created (evicted or cleared). With `count`, it
    /// maps a position seen earlier onto the current indices in O(1).
    var removedCount: Int { get }
    subscript(index: Int) -> LogEntry { get }
    /// Smallest n (1...maxCount, at most `count`) of oldest entries whose cached sizes sum to at
    /// least `bytes`; stops early (but returns at least 1) before the first entry other than
    /// the oldest dated `olderThan` or later. Uses cached sizes, no recomputation.
    func evictionCount(coveringBytes bytes: Int, maxCount: Int, olderThan: Date) -> Int
    func append(contentsOf: [LogEntry])
    func removeOldest(_ n: Int)
    func removeAll()
}
