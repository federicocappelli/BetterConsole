/// The log table's bookkeeping over a session's `rows`, without AppKit: which row of `rows`
/// a table row shows between updates, and on each update how to reload, which message to keep
/// at the top of the visible area and which row to select. The table applies the decisions.
///
/// Rows are identified by absolute position (`LogRows.position(ofRow:)`), which survives
/// eviction, rescans (rows inserted at the front) and filter changes (resets).
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

    public enum SelectionChange: Equatable, Sendable {
        case keep
        /// Select `row` (the selected message's row now); the detail pane already shows it.
        case select(row: Int)
        /// Clear the table's selection; with `clearDetail`, the detail pane too.
        case deselect(clearDetail: Bool)
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
        /// The user selected row `row` of `rows`.
        case entry(row: Int)
        /// The user cleared the selection.
        case cleared
        /// The clicked table row no longer maps to a row (rows replaced since the last
        /// update): undo the table's selection and keep everything else.
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
    /// Absolute position of the selected message, kept while the detail pane shows it.
    public private(set) var selectedPosition: Int?
    /// False while the selected message is not a row (filtered out): the table shows no
    /// selection, the detail pane still shows the message.
    public private(set) var isSelectionShown = false

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
            selection: selectionChange(session, isReset: isReset, shifted: shifted))
    }

    private func selectionChange(
        _ session: StreamSession, isReset: Bool, shifted: Bool
    ) -> SelectionChange {
        guard let position = selectedPosition else { return .keep }
        if position < session.store.removedCount {
            // Evicted or cleared, whether the table showed it or not.
            selectedPosition = nil
            isSelectionShown = false
            return .deselect(clearDetail: true)
        }
        // A shown selection only moves when rows shift; a hidden one is looked for on every
        // update, as the rescan's front inserts (shifts, not resets) can bring it back.
        if isSelectionShown, !shifted { return .keep }
        if let row = session.rows.row(forPosition: position) {
            isSelectionShown = true
            return .select(row: row)
        }
        let wasShown = isSelectionShown
        isSelectionShown = false
        return wasShown || isReset ? .deselect(clearDetail: false) : .keep
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
        guard let tableRow else {
            selectedPosition = nil
            isSelectionShown = false
            return .cleared
        }
        guard let current = currentRow(forTableRow: tableRow, in: rows) else {
            // The table no longer shows the selected message as selected; the next update
            // selects it again if it is a row.
            isSelectionShown = false
            return .ignored
        }
        selectedPosition = rows.position(ofRow: current)
        isSelectionShown = true
        return .entry(row: current)
    }
}
