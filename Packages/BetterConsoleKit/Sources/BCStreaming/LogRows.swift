import BCModel
import BCStore

/// The log table's view of one session: every stored message (unfiltered) or only the matching
/// ones (filtered). A row's position is the message's absolute position in the session, which
/// is `store.removedCount` plus its store index, so it stays valid while older messages are
/// evicted.
@MainActor
public final class LogRows {
    private let store: any LogStore
    private var index = MatchIndex()
    private var removedBase = 0

    /// Rows added at the front / removed from the front since the last reset. Unfiltered, the
    /// removed count follows the store's `removedCount`.
    public private(set) var insertedAtFront = 0
    private var filteredRemovedFromFront = 0
    public var removedFromFront: Int {
        isFiltered ? filteredRemovedFromFront : store.removedCount - removedBase
    }
    /// Bumped whenever the row set is replaced (filter change, `clear()`).
    public private(set) var resetCount = 0
    public private(set) var isFiltered = false

    init(store: any LogStore) {
        self.store = store
        removedBase = store.removedCount
    }

    public var count: Int { isFiltered ? index.count : store.count }

    public subscript(row: Int) -> LogEntry {
        store[position(ofRow: row) - store.removedCount]
    }

    public func position(ofRow row: Int) -> Int {
        isFiltered ? index[row] : store.removedCount + row
    }

    public func row(forPosition position: Int) -> Int? {
        if isFiltered { return index.row(forPosition: position) }
        let row = position - store.removedCount
        return row >= 0 && row < store.count ? row : nil
    }

    public func row(atOrBefore position: Int) -> Int? {
        if isFiltered { return index.row(atOrBefore: position) }
        let row = min(position - store.removedCount, store.count - 1)
        return row >= 0 ? row : nil
    }

    /// The first row whose position is at or after `position`, or nil if none is.
    public func row(atOrAfter position: Int) -> Int? {
        let row: Int
        if isFiltered {
            row = index.row(atOrBefore: position - 1).map { $0 + 1 } ?? 0
        } else {
            row = Swift.max(0, position - store.removedCount)
        }
        return row < count ? row : nil
    }

    /// The rows as they are now, for reading later (Save Logs). O(1).
    public func snapshot() -> RowSnapshot {
        isFiltered
            ? RowSnapshot(storage: .filtered(index))
            : RowSnapshot(storage: .contiguous(store.removedCount..<store.removedCount + store.count))
    }

    /// Replaces the rows with a filtered set and starts a new reset generation.
    func installFiltered(_ newIndex: MatchIndex) {
        index = newIndex
        isFiltered = true
        reset()
    }

    /// Back to showing every stored message.
    func installUnfiltered() {
        index = MatchIndex()
        isFiltered = false
        reset()
    }

    /// Rescan result: older matches, newest first, all below the current first row.
    func prependRescan(_ positionsNewestFirst: [Int]) {
        index.prepend(positionsNewestFirst)
        insertedAtFront += positionsNewestFirst.count
    }

    /// A live match, above every current row.
    func appendLive(_ position: Int) {
        index.append(position)
    }

    /// Drops rows whose messages the store evicted. No-op unfiltered (rows follow the store).
    func dropEvicted() {
        guard isFiltered else { return }
        filteredRemovedFromFront += index.dropBelow(store.removedCount)
    }

    /// The store was cleared: no rows, counters back to zero, new reset generation.
    func clear() {
        index.removeAll()
        reset()
    }

    private func reset() {
        resetCount += 1
        insertedAtFront = 0
        filteredRemovedFromFront = 0
        removedBase = store.removedCount
    }
}
