/// The log table's bookkeeping over a session's `rows`, without AppKit: which row of `rows`
/// a table row shows between updates, and on each update how to reload, which message to keep
/// at the top of the visible area and which rows to select. The table applies the decisions.
///
/// Rows are identified by absolute position (`LogRows.position(ofRow:)`), which survives
/// eviction, rescans (rows inserted at the front) and filter changes (resets). The selection
/// is a set of position ranges: a range taken from the rows a, a+1, …, b covers every position
/// from a's to b's, so ⌘A over any number of rows is one range, and mapping it to table rows
/// costs two row lookups per range. A range is only mapped through the rows it was taken
/// from: a filter change clears a selection of several rows (one row survives it).
@MainActor
public final class RowViewport {
    /// The message at the top of the visible area and how far the visible area starts below
    /// its row's top, in points.
    public struct Anchor: Equatable, Sendable {
        public var position: Int
        public var offset: Double
    }

    public enum Reload: Equatable, Sendable {
        /// Nothing changed in the row count or indices.
        case none
        /// Rows were added or removed at the end only, or shifted with views kept.
        case numberOfRows
        /// Every row was replaced, or all of them removed: reload the table.
        case all
    }

    public enum ScrollTarget: Equatable, Sendable {
        /// Put `row`'s top `offset` points above the top of the visible area.
        case row(Int, offset: Double)
        /// The oldest row at the top.
        case top
    }

    /// What the detail pane shows for the rows the table shows selected.
    public enum Detail: Equatable, Sendable {
        /// None of the selected messages is a row (filtered out): keep what it shows.
        case keep
        /// One selected row: its message.
        case entry(row: Int)
        /// Several: "N messages selected".
        case count(Int)
    }

    public enum SelectionChange: Equatable, Sendable {
        case keep
        /// Show exactly `rows` (ascending, disjoint table row ranges, possibly none) as
        /// selected, and `detail` in the detail pane.
        case select(rows: [Range<Int>], detail: Detail)
        /// The selection is gone (evicted or cleared): clear the table's selection and the
        /// detail pane.
        case clear
    }

    /// What an update does to the table.
    public struct Update: Equatable, Sendable {
        public let count: Int
        public let previousCount: Int
        public let isReset: Bool
        public let reload: Reload
        /// Re-fetch the cells of rows that have views (indices shifted, views kept).
        public let refreshRowsWithViews: Bool
        /// Where to scroll when not following; nil leaves the scroll position alone.
        public let scroll: ScrollTarget?
        public let selection: SelectionChange
    }

    public enum UserSelection: Equatable, Sendable {
        /// The user selected one row, row `row` of `rows`.
        case entry(row: Int)
        /// The user selected `count` rows.
        case several(count: Int)
        /// The user cleared the selection.
        case cleared
        /// None of the selected table rows maps to a row any more (rows replaced or evicted
        /// since the last update): undo the table's selection and keep everything else.
        case ignored
    }

    /// The number of rows the table shows, and `rows`' counters when they were shown.
    public private(set) var shownCount = 0
    private var shownInserted = 0
    private var shownRemoved = 0
    private var shownResetCount = 0

    public private(set) var anchor: Anchor?
    /// True from a reset (not following) until the anchor's message, or the nearest older
    /// match, is a row again, the rescan ends, or the user scrolls. Meanwhile the anchor is
    /// not replaced by whatever the table shows (spec §8.1: same entry at the top during a
    /// rescan, else the nearest older match).
    public private(set) var isAnchorPending = false
    /// Absolute positions of the selected messages; evicted ones drop out. A single selected
    /// message that is not a row (filtered out) stays selected and shows selected again once
    /// it is a row; a selection of several is cleared by a filter change. A selection of
    /// several that eviction leaves one message of is a single selection from then on, and
    /// survives filter changes like one.
    public private(set) var selection = PositionRanges()
    /// False when the table may not show `selection` as it maps now (the user's selection
    /// was ignored): the next update re-applies it even if no rows shifted.
    private var isSelectionApplied = true

    public init() {}

    /// The row of `rows` the table's `row` shows, or nil if it has been removed since the
    /// last update or every row was replaced. O(1).
    public func currentRow(forTableRow row: Int, in rows: LogRows) -> Int? {
        guard rows.resetCount == shownResetCount else { return nil }
        let current = row + (rows.insertedAtFront - shownInserted)
            - (rows.removedFromFront - shownRemoved)
        return current >= 0 && current < rows.count ? current : nil
    }

    /// Brings the shown state up to `session.rows` and decides what the table does.
    public func apply(_ session: StreamSession, following: Bool) -> Update {
        let rows = session.rows
        let count = rows.count
        let isReset = rows.resetCount != shownResetCount
        let inserted = isReset ? 0 : rows.insertedAtFront - shownInserted
        let removed = isReset ? 0 : rows.removedFromFront - shownRemoved
        let shifted = isReset || inserted != 0 || removed != 0
        let previousCount = shownCount
        shownCount = count
        shownInserted = rows.insertedAtFront
        shownRemoved = rows.removedFromFront
        shownResetCount = rows.resetCount

        let reload: Reload =
            shifted && (isReset || removed >= previousCount || count == 0) ? .all
            : count != previousCount ? .numberOfRows : .none

        var scroll: ScrollTarget?
        if following {
            isAnchorPending = false
        } else if isReset, anchor != nil {
            isAnchorPending = true
        }
        if shifted, !following, let anchor, count > 0 {
            if let row = rows.row(forPosition: anchor.position) {
                scroll = .row(row, offset: anchor.offset)
                isAnchorPending = false
            } else if let row = rows.row(atOrBefore: anchor.position) {
                // The rescan adds older rows newest first: the first one found at or before
                // the anchor is the nearest older match.
                scroll = .row(row, offset: 0)
                isAnchorPending = false
            } else {
                scroll = .top
            }
        } else if isReset, !following, count == 0 {
            // Nothing to keep at the top yet: say so, so AppKit's later clamp of the clip view
            // is not taken for a user scroll that would drop the pending anchor.
            scroll = .top
        }
        if isAnchorPending, !session.isFiltering { isAnchorPending = false }

        return Update(
            count: count, previousCount: previousCount, isReset: isReset, reload: reload,
            refreshRowsWithViews: shifted && !isReset && removed < previousCount && count > 0,
            scroll: scroll,
            selection: selectionChange(session, shifted: shifted, isReset: isReset))
    }

    private func selectionChange(
        _ session: StreamSession, shifted: Bool, isReset: Bool
    ) -> SelectionChange {
        guard !selection.isEmpty else { return .keep }
        selection.removeBelow(session.store.removedCount)
        // Several rows: their ranges were taken from the rows of one filter and would stand
        // for other rows under another, so a filter change (reset) clears them. A single
        // message stays selected across it.
        if isReset, !isSingle { selection.removeAll() }
        if selection.isEmpty {
            // Evicted or cleared, whether the table showed it or not.
            isSelectionApplied = true
            return .clear
        }
        // Rows appended at the end come after every selected position: the table's
        // selection only moves when rows shift (eviction, rescan inserts, reset).
        if isSelectionApplied, !shifted { return .keep }
        isSelectionApplied = true
        let rows = selectedRows(in: session.rows)
        let count = rows.reduce(0) { $0 + $1.count }
        let detail: Detail
        switch count {
        case 0:
            // A single message filtered out keeps its details; several are gone (evicted).
            guard isSingle else {
                selection.removeAll()
                return .clear
            }
            detail = .keep
        case 1: detail = .entry(row: rows[0].lowerBound)
        default: detail = .count(count)
        }
        return .select(rows: rows, detail: detail)
    }

    /// The selection for Copy, with the row generation it belongs to (the one the table
    /// shows; none for a single message, whose position is valid under any filter).
    public var selectionForCopy: SelectedPositions {
        SelectedPositions(positions: selection, resetCount: isSingle ? nil : shownResetCount)
    }

    /// The selection is one message.
    private var isSingle: Bool {
        selection.ranges.count == 1 && selection.ranges[0].count == 1
    }

    /// The rows of `rows` whose positions are selected, as ascending, disjoint ranges.
    /// O(ranges × log rows).
    public func selectedRows(in rows: LogRows) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in selection.ranges {
            guard let low = rows.row(atOrAfter: range.lowerBound),
                  let high = rows.row(atOrBefore: range.upperBound - 1), low <= high
            else { continue }
            if let last = result.last, last.upperBound == low {
                result[result.count - 1] = last.lowerBound..<high + 1
            } else {
                result.append(low..<high + 1)
            }
        }
        return result
    }

    /// Records the message at the top of the visible area: `tableRow` (nil if no row is
    /// there) with `offset`. `byUser`: the user scrolled (or resized), not an update.
    public func recordTop(tableRow: Int?, offset: Double, in rows: LogRows, byUser: Bool) {
        if byUser { isAnchorPending = false }
        guard !isAnchorPending else { return }
        guard let tableRow else {
            if shownCount == 0 { anchor = nil }
            return
        }
        guard let current = currentRow(forTableRow: tableRow, in: rows) else { return }
        anchor = Anchor(position: rows.position(ofRow: current), offset: offset)
    }

    /// The user changed the table's selection to `tableRow` (nil: none).
    public func userSelected(tableRow: Int?, in rows: LogRows) -> UserSelection {
        userSelected(tableRows: tableRow.map { [$0..<$0 + 1] } ?? [], in: rows)
    }

    /// The user changed the table's selection to `tableRows` (ascending, disjoint table row
    /// ranges; empty: none). It replaces the selection, hidden positions included. Table rows
    /// no longer rows (evicted since the last update) are left out; if none is left, or every
    /// row was replaced since, the change is ignored. O(ranges).
    public func userSelected(tableRows: [Range<Int>], in rows: LogRows) -> UserSelection {
        guard !tableRows.isEmpty else {
            selection.removeAll()
            isSelectionApplied = true
            return .cleared
        }
        var positions: [Range<Int>] = []
        var count = 0
        var single: Int?
        if rows.resetCount == shownResetCount {
            // Table row t shows row t + shift while it is in 0..<rows.count.
            let shift = (rows.insertedAtFront - shownInserted) - (rows.removedFromFront - shownRemoved)
            for range in tableRows {
                let low = Swift.max(range.lowerBound + shift, 0)
                let high = Swift.min(range.upperBound + shift, rows.count)
                guard low < high else { continue }
                positions.append(rows.position(ofRow: low)..<rows.position(ofRow: high - 1) + 1)
                count += high - low
                single = low
            }
        }
        guard count > 0, let single else {
            // The table no longer shows the selection; the next update selects it again.
            isSelectionApplied = false
            return .ignored
        }
        selection = PositionRanges(positions)
        // The table's own selection may include rows that are gone: re-apply on the update.
        isSelectionApplied = count == tableRows.reduce(0) { $0 + $1.count }
        return count == 1 ? .entry(row: single) : .several(count: count)
    }
}

/// Spaces out count-only changes of the detail pane ("N messages selected" while eviction
/// shrinks a selection, every update) to one per `interval`, so the SwiftUI view around the
/// table is not rebuilt on every update; any other change goes out at once.
public struct CountUpdateThrottle: Sendable {
    public static let interval = Duration.milliseconds(250)
    private var lastSent: ContinuousClock.Instant?

    public init() {}

    /// How long to wait before sending a change at `now` (zero: send it now, recorded as
    /// sent). `countOnly`: only the count of selected rows changes.
    public mutating func delay(at now: ContinuousClock.Instant, countOnly: Bool) -> Duration {
        if countOnly, let lastSent, now - lastSent < Self.interval {
            return Self.interval - (now - lastSent)
        }
        lastSent = now
        return .zero
    }
}
