import Foundation
import Testing
import BCFilter
import BCModel
import BCStore
import BCTransport
@testable import BCStreaming

/// The log table's decisions, driven through a real `StreamSession`: entries come from
/// `FakeTransport`, filters are set and rescanned in steps (`maxRescanChunk`,
/// `afterRescanCopy`), and a fake table applies each `Update` the way the coordinator does.
/// Entry `i` is streamed `i`-th, so its absolute position is `i`; its process cycles A, B, C.
@MainActor
struct RowViewportTests {
    let transport = FakeTransport()

    /// The part of the table the decisions act on: which row is at the top of the visible
    /// area and which rows are selected, plus what the detail pane shows.
    @MainActor final class FakeTable {
        let session: StreamSession
        let viewport = RowViewport()
        var top: Int?
        var topOffset: Double = 0
        /// Selected table rows, ascending and disjoint (as `IndexSet.rangeView`).
        var selectedRows: [Range<Int>] = []
        /// Position of the message the detail pane shows.
        var detail: Int?
        /// The detail pane's "N messages selected", or nil.
        var detailCount: Int?
        /// The row a plain or ⌘-click last hit: ⇧-click extends from it (as NSTableView).
        var clickAnchor: Int?
        var updates: [RowViewport.Update] = []

        init(session: StreamSession) { self.session = session }

        /// One coordinator update: apply, scroll, select, record the top.
        @discardableResult
        func update(following: Bool = false) -> RowViewport.Update {
            let u = viewport.apply(session, following: following)
            updates.append(u)
            switch u.scroll {
            case .row(let row, let offset): (top, topOffset) = (row, offset)
            case .top: (top, topOffset) = (u.count > 0 ? 0 : nil, 0)
            case nil: break
            }
            if following { (top, topOffset) = (u.count > 0 ? max(0, u.count - 30) : nil, 0) }
            if let t = top, t >= u.count { (top, topOffset) = (u.count > 0 ? u.count - 1 : nil, 0) }
            switch u.selection {
            case .keep: break
            case .select(let rows, let shown):
                selectedRows = rows
                switch shown {
                case .keep: break
                case .entry(let row): (detail, detailCount) = (session.rows.position(ofRow: row), nil)
                case .count(let n): (detail, detailCount) = (nil, n)
                }
            case .clear:
                selectedRows = []
                (detail, detailCount) = (nil, nil)
            }
            viewport.recordTop(tableRow: top, offset: topOffset, in: session.rows, byUser: false)
            return u
        }

        /// The user scrolls so that table row `row` is at the top.
        func scroll(toTableRow row: Int, offset: Double = 0) {
            (top, topOffset) = (row, offset)
            viewport.recordTop(tableRow: row, offset: offset, in: session.rows, byUser: true)
        }

        /// The table's selection became `rows` (a click, ⇧/⌘-click or Select All).
        func userChanged(_ rows: [Range<Int>]) {
            selectedRows = rows
            switch viewport.userSelected(tableRows: rows, in: session.rows) {
            case .entry(let r): (detail, detailCount) = (session.rows.position(ofRow: r), nil)
            case .several(let n): (detail, detailCount) = (nil, n)
            case .cleared: (detail, detailCount) = (nil, nil)
            case .ignored: selectedRows = []
            }
        }

        /// The user clicks table row `row` (nil: empty space, clearing the selection).
        func click(tableRow row: Int?) {
            clickAnchor = row
            userChanged(row.map { [$0..<$0 + 1] } ?? [])
        }

        /// ⇧-click: the rows from the click anchor to `row` replace the selection.
        func shiftClick(tableRow row: Int) {
            let anchor = clickAnchor ?? row
            userChanged([min(anchor, row)..<max(anchor, row) + 1])
        }

        /// ⌘-click: toggles `row`.
        func commandClick(tableRow row: Int) {
            clickAnchor = row
            var set = Set(selectedRows.joined())
            if set.contains(row) { set.remove(row) } else { set.insert(row) }
            var ranges: [Range<Int>] = []
            for r in set.sorted() {
                if let last = ranges.last, last.upperBound == r {
                    ranges[ranges.count - 1] = last.lowerBound..<r + 1
                } else {
                    ranges.append(r..<r + 1)
                }
            }
            userChanged(ranges)
        }

        /// ⌘A: every row the table shows.
        func selectAll() {
            userChanged(viewport.shownCount > 0 ? [0..<viewport.shownCount] : [])
        }

        /// The single selected row, or nil if none or several are selected.
        var selected: Int? {
            selectedRows.count == 1 && selectedRows[0].count == 1 ? selectedRows[0].lowerBound : nil
        }

        /// Absolute position of the message at the top / selected, as the table shows them.
        var topPosition: Int? { top.map { session.rows.position(ofRow: $0) } }
        var selectedPosition: Int? { selected.map { session.rows.position(ofRow: $0) } }
        /// Absolute positions of every row the table shows selected (small selections).
        var selectedPositions: [Int] { selectedRows.joined().map(session.rows.position(ofRow:)) }
    }

    func makeSession(budget: MemoryBudget = MemoryBudget()) -> StreamSession {
        let s = StreamSession(
            device: mac, transport: transport, budget: budget, drainInterval: .milliseconds(5))
        s.maxRescanChunk = 1_000
        return s
    }

    func stream(_ range: Range<Int>, batch: Int = 1_000) {
        let processes = ["A", "B", "C"]
        var low = range.lowerBound
        while low < range.upperBound {
            let high = min(low + batch, range.upperBound)
            transport.yield((low..<high).map {
                makeEntry(UInt64($0), process: processes[$0 % 3])
            })
            low = high
        }
    }

    func processIs(_ value: String) -> FilterExpression {
        .condition(FilterCondition(field: .process, match: .is, value: value))
    }

    func settle(_ s: StreamSession, total: Int) async -> Bool {
        await eventually(timeout: .seconds(5)) { s.appendedCount == total && !s.isFiltering }
    }

    /// A session holding positions 0..<10,000, unfiltered, shown in `table` (scrolled to
    /// the bottom, as when following).
    func streamed(_ total: Int = 10_000, budget: MemoryBudget = MemoryBudget()) async
        -> (StreamSession, FakeTable)
    {
        let s = makeSession(budget: budget)
        s.start()
        stream(0..<total)
        #expect(await settle(s, total: total))
        let table = FakeTable(session: s)
        table.update(following: true)
        return (s, table)
    }

    // MARK: Mapping between updates

    @Test func frontRemovalsBetweenUpdates() async {
        let budget = MemoryBudget()
        let (s, table) = await streamed(budget: budget)
        let perEntry = s.store.estimatedBytes / s.store.count
        // Evict the oldest 100: table row 500 still shows position 500, row 50 is gone.
        budget.limitBytes = perEntry * (s.store.count - 100)
        #expect(s.store.removedCount == 100)
        let v = table.viewport
        #expect(v.currentRow(forTableRow: 50, in: s.rows) == nil)
        #expect(v.currentRow(forTableRow: 500, in: s.rows).map(s.rows.position(ofRow:)) == 500)
        let u = table.update()
        #expect(u.reload == .numberOfRows)
        #expect(u.refreshRowsWithViews)
        #expect(v.currentRow(forTableRow: 400, in: s.rows).map(s.rows.position(ofRow:)) == 500)

        #expect(v.currentRow(forTableRow: 0, in: s.rows).map(s.rows.position(ofRow:)) == 100)
    }

    @Test func rowsMapAcrossAPrependBeforeTheUpdate() async {
        let (s, table) = await streamed()
        var before: [Int] = []
        var after: [Int?] = []
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            if copies == 2 {
                table.update()
                before = (0..<s.rows.count).map(s.rows.position(ofRow:))
            } else if copies == 3 {
                // One more chunk was prepended; the table still shows the old rows.
                #expect(s.rows.insertedAtFront > 0)
                after = (0..<before.count).map {
                    table.viewport.currentRow(forTableRow: $0, in: s.rows)
                        .map(s.rows.position(ofRow:))
                }
            }
        }
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        #expect(!before.isEmpty)
        #expect(after == before.map { Optional($0) })
    }

    // MARK: Top anchor

    /// Scrolled up to position 6,000 (an A) when filter A is set: the reset and the newer
    /// chunks keep the anchor, and once its chunk is in, it is back at the top.
    @Test func filterChangeWhileScrolledUpKeepsTheTopMessage() async {
        let (s, table) = await streamed()
        table.scroll(toTableRow: 6_000, offset: 4)
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            table.update()
            #expect(table.viewport.anchor?.position == 6_000)
        }
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(copies >= 4)
        #expect(table.topPosition == 6_000)
        #expect(table.viewport.anchor == .init(position: 6_000, offset: 4))
        #expect(table.updates.contains {
            $0.scroll == .row(s.rows.row(forPosition: 6_000)!, offset: 4)
        })
    }

    /// The reset leaves no rows yet (the rescan has added none): the table is told to go to
    /// the top, so AppKit's later clamp of the clip view is the update's own scroll, not one
    /// read as the user's that would drop the pending anchor.
    @Test func resetToZeroRowsScrollsToTheTop() async {
        let (s, table) = await streamed()
        table.scroll(toTableRow: 6_000, offset: 4)
        s.setFilter(processIs("A"))
        let u = table.update()
        #expect(u.isReset)
        #expect(u.count == 0)
        #expect(u.scroll == .top)
        #expect(table.viewport.isAnchorPending)
        #expect(table.viewport.anchor == .init(position: 6_000, offset: 4))
        s.afterRescanCopy = { table.update() }
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(table.topPosition == 6_000)
        #expect(table.viewport.anchor == .init(position: 6_000, offset: 4))
        // Following: no scroll target at all, even on an empty reset.
        table.update(following: true)
        s.setFilter(processIs("B"))
        #expect(table.update(following: true).scroll == nil)
    }

    /// The top message (6,001, a B) does not match A: the nearest older match (6,000).
    @Test func filterChangeAnchorsToTheNearestOlderMatch() async {
        let (s, table) = await streamed()
        table.scroll(toTableRow: 6_001)
        s.afterRescanCopy = { table.update() }
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(table.topPosition == 6_000)
        // Resolved: later rescans or updates keep 6,000, not 6,001.
        #expect(table.viewport.anchor?.position == 6_000)
    }

    /// Nothing at or below the anchor matches: once the rescan is done the table stays at
    /// the oldest row and the anchor follows what is shown again.
    @Test func unresolvedAnchorEndsWithTheRescan() async {
        let s = makeSession()
        s.start()
        stream(0..<3_000)
        transport.yield([makeEntry(3_000, process: "Z"), makeEntry(3_001, process: "Z")])
        #expect(await settle(s, total: 3_002))
        let table = FakeTable(session: s)
        table.update(following: true)
        table.scroll(toTableRow: 1_000)
        s.afterRescanCopy = { table.update() }
        s.setFilter(processIs("Z"))
        #expect(await settle(s, total: 3_002))
        table.update()
        #expect(table.topPosition == 3_000)
        #expect(table.viewport.anchor?.position == 3_000)
    }

    /// The user scrolling during the rescan replaces the pending anchor.
    @Test func userScrollReplacesThePendingAnchor() async {
        let (s, table) = await streamed()
        table.scroll(toTableRow: 2_000)
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            table.update()
            if copies == 2, s.rows.count > 10 {
                table.scroll(toTableRow: 10)  // a row the rescan already added
            }
        }
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(table.viewport.anchor?.position != 2_000)
        #expect(table.topPosition == table.viewport.anchor?.position)
        #expect(table.topPosition.map { $0 > 2_000 } == true)
    }

    // MARK: Selection

    /// on > off > on with a selection and a top anchor, through the same session.
    @Test func filterOnOffOnKeepsSelectionAndAnchor() async {
        let (s, table) = await streamed()
        table.scroll(toTableRow: 5_990)
        table.click(tableRow: 6_000)
        #expect(table.detail == 6_000)

        s.afterRescanCopy = { table.update() }
        s.setFilter(processIs("A"))  // 6,000 matches
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(table.selectedPosition == 6_000)
        #expect(table.detail == 6_000)

        s.setFilter(nil)
        table.update()
        #expect(table.selectedPosition == 6_000)
        #expect(table.topPosition == 5_988)  // the A the filtered view had at the top
        #expect(table.detail == 6_000)

        s.setFilter(processIs("B"))  // 6,000 does not match: detail kept, no selection
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(table.selected == nil)
        #expect(table.detail == 6_000)
        #expect(table.topPosition == 5_986)  // nearest older B

        s.setFilter(nil)  // back again: selected on its row
        table.update()
        #expect(table.selectedPosition == 6_000)
        #expect(table.detail == 6_000)
        #expect(table.topPosition == 5_986)
    }

    /// Selected before the filter, hidden at the reset, selected again once the rescan has
    /// added its row (a shift, not a reset); the detail pane never clears.
    @Test func selectionComesBackWhenTheRescanAddsItsRow() async {
        let (s, table) = await streamed()
        table.click(tableRow: 6_000)
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            table.update()
            if copies == 1 { #expect(table.selected == nil) }
            #expect(table.detail == 6_000)
        }
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(table.selectedPosition == 6_000)
        #expect(table.viewport.selectedRows(in: s.rows) == [table.selected!..<table.selected! + 1])
    }

    @Test func clearWhileFilteredClearsSelectionAndDetail() async {
        let (s, table) = await streamed()
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        table.click(tableRow: s.rows.row(forPosition: 6_000))
        #expect(table.detail == 6_000)
        s.clear()
        let u = table.update()
        #expect(u.selection == .clear)
        #expect(table.detail == nil)
        #expect(table.viewport.selection.isEmpty)
    }

    /// Hidden by the filter (6,001 is a B), then evicted: the detail pane clears.
    @Test func evictingAHiddenSelectionClearsTheDetail() async {
        let budget = MemoryBudget()
        let (s, table) = await streamed(budget: budget)
        table.click(tableRow: 6_001)
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(table.selected == nil)
        #expect(table.detail == 6_001)

        let perEntry = s.store.estimatedBytes / s.store.count
        budget.limitBytes = perEntry * 3_000  // evicts 0..<7,000
        let u = table.update()
        #expect(u.selection == .clear)
        #expect(table.detail == nil)
        #expect(table.viewport.selection.isEmpty)
    }

    @Test func evictingAShownSelectionClearsIt() async {
        let budget = MemoryBudget()
        let (s, table) = await streamed(budget: budget)
        table.click(tableRow: 100)
        let perEntry = s.store.estimatedBytes / s.store.count
        budget.limitBytes = perEntry * (s.store.count - 200)
        let u = table.update()
        #expect(u.selection == .clear)
        #expect(table.detail == nil)
    }

    /// A click between a reset and the next update hits a row that no longer maps: ignored,
    /// the detail pane keeps what it showed.
    @Test func clickBetweenResetAndUpdateIsIgnored() async {
        let (s, table) = await streamed()
        table.click(tableRow: 6_000)
        s.setFilter(processIs("A"))
        table.click(tableRow: 10)
        #expect(table.detail == 6_000)
        #expect(table.viewport.selection.ranges == [6_000..<6_001])
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(table.selectedPosition == 6_000)
    }

    // MARK: Multiple selection

    /// ⌘A selects every row there is; evicting the oldest drops their positions, and evicting
    /// the rest clears the selection and the detail pane.
    @Test func selectAllThenEvictionDropsTheEvictedPositions() async {
        let budget = MemoryBudget()
        let (s, table) = await streamed(budget: budget)
        table.selectAll()
        #expect(table.viewport.selection.ranges == [0..<10_000])
        #expect(table.detailCount == 10_000)

        let perEntry = s.store.estimatedBytes / s.store.count
        budget.limitBytes = perEntry * (s.store.count - 100)
        let u = table.update()
        #expect(table.viewport.selection.ranges == [100..<10_000])
        #expect(u.selection == .select(rows: [0..<9_900], detail: .count(9_900)))
        #expect(table.detailCount == 9_900)

        budget.limitBytes = 0
        #expect(s.store.count == 0)
        #expect(table.update().selection == .clear)
        #expect(table.viewport.selection.isEmpty)
        #expect(table.detailCount == nil)
    }

    /// Rows that arrive after ⌘A are not selected.
    @Test func selectAllThenNewRowsAreNotSelected() async {
        let (s, table) = await streamed()
        table.selectAll()
        stream(10_000..<10_500)
        #expect(await settle(s, total: 10_500))
        let u = table.update()
        #expect(u.count == 10_500)
        #expect(u.selection == .keep)
        #expect(table.selectedRows == [0..<10_000])
        #expect(table.viewport.selectedRows(in: s.rows) == [0..<10_000])
        #expect(table.detailCount == 10_000)
    }

    /// ⌘A during a rescan selects the rows found so far; older rows the rescan adds after it
    /// are not selected.
    @Test func selectAllDuringARescanLeavesLaterRescanRowsOut() async {
        let (s, table) = await streamed()
        var copies = 0
        var selectedAt: [Range<Int>] = []
        s.afterRescanCopy = {
            copies += 1
            table.update()
            if copies == 3 {
                table.selectAll()
                selectedAt = table.viewport.selection.ranges
            }
        }
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        let first = try! #require(selectedAt.first?.lowerBound)
        #expect(first > 0)
        let firstRow = s.rows.row(forPosition: first)!
        #expect(firstRow > 0)  // older matches were added below it
        #expect(table.selectedRows == [firstRow..<s.rows.count])
        #expect(table.detailCount == s.rows.count - firstRow)
    }

    /// ⇧-click selects the range from the clicked row; the detail pane counts it.
    @Test func shiftClickSelectsARange() async {
        let (_, table) = await streamed()
        table.click(tableRow: 100)
        #expect(table.detail == 100)
        table.shiftClick(tableRow: 105)
        #expect(table.viewport.selection.ranges == [100..<106])
        #expect((table.detail, table.detailCount) == (nil, 6))
        table.shiftClick(tableRow: 98)  // the anchor stays at 100
        #expect(table.viewport.selection.ranges == [98..<101])
        #expect(table.detailCount == 3)
        #expect(table.update().selection == .keep)
    }

    /// ⌘-click adds and removes single rows; one row left shows its details again.
    @Test func commandClickToggles() async {
        let (_, table) = await streamed()
        table.click(tableRow: 100)
        table.commandClick(tableRow: 102)
        table.commandClick(tableRow: 104)
        #expect(table.viewport.selection.ranges == [100..<101, 102..<103, 104..<105])
        #expect(table.detailCount == 3)
        table.commandClick(tableRow: 101)
        #expect(table.viewport.selection.ranges == [100..<103, 104..<105])
        #expect(table.detailCount == 4)
        table.commandClick(tableRow: 100)
        table.commandClick(tableRow: 101)
        table.commandClick(tableRow: 102)
        #expect(table.viewport.selection.ranges == [104..<105])
        #expect((table.detail, table.detailCount) == (104, nil))
        table.commandClick(tableRow: 104)
        #expect(table.viewport.selection.isEmpty)
        #expect((table.detail, table.detailCount) == (nil, nil))
    }

    /// Several rows selected without a filter: a filter change clears the selection and the
    /// detail pane (a range would otherwise stand for rows the new filter hides or shows).
    @Test func filterChangeClearsAMultiSelection() async {
        let (s, table) = await streamed()
        table.click(tableRow: 6_000)
        table.shiftClick(tableRow: 6_010)
        #expect(table.detailCount == 11)
        s.setFilter(processIs("A"))
        #expect(table.update().selection == .clear)
        #expect(table.viewport.selection.isEmpty)
        #expect((table.detail, table.detailCount) == (nil, nil))
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(table.selectedRows.isEmpty)
        s.setFilter(nil)
        table.update()
        #expect(table.selectedRows.isEmpty)
    }

    /// Several rows selected under a filter stay exact while it stays; changing it (to
    /// another filter or none) clears them. A single row still survives filter changes.
    @Test func multiSelectionUnderAFilter() async {
        let (s, table) = await streamed()
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        table.click(tableRow: s.rows.row(forPosition: 6_000))
        table.shiftClick(tableRow: s.rows.row(forPosition: 6_009)!)
        #expect(table.selectedPositions == [6_000, 6_003, 6_006, 6_009])
        #expect(table.detailCount == 4)
        stream(10_000..<10_300)
        #expect(await settle(s, total: 10_300))
        #expect(table.update().selection == .keep)
        #expect(table.selectedPositions == [6_000, 6_003, 6_006, 6_009])

        s.setFilter(processIs("B"))
        #expect(table.update().selection == .clear)
        #expect(await settle(s, total: 10_300))
        table.update()
        #expect(table.selectedRows.isEmpty)
        #expect((table.detail, table.detailCount) == (nil, nil))

        // Again under A, then no filter: cleared too.
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_300))
        table.update()
        table.click(tableRow: s.rows.row(forPosition: 6_000))
        table.shiftClick(tableRow: s.rows.row(forPosition: 6_003)!)
        s.setFilter(nil)
        #expect(table.update().selection == .clear)
        #expect(table.selectedRows.isEmpty)

        // One row: kept across the change, as before.
        table.click(tableRow: 6_001)
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_300))
        table.update()
        #expect(table.selected == nil)
        #expect(table.detail == 6_001)
        s.setFilter(nil)
        table.update()
        #expect(table.selectedPosition == 6_001)
    }

    /// Eviction updates the detail pane's count, shows the details once one row is left, and
    /// clears the selection and the pane once none is.
    @Test func evictionUpdatesTheCountThenClears() async {
        let budget = MemoryBudget()
        let (s, table) = await streamed(budget: budget)
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        table.click(tableRow: s.rows.row(forPosition: 6_000))
        table.shiftClick(tableRow: s.rows.row(forPosition: 6_009)!)
        #expect(table.detailCount == 4)
        let perEntry = s.store.estimatedBytes / s.store.count

        budget.limitBytes = perEntry * (10_000 - 6_004)  // evicts 0..<6,004
        let u = table.update()
        #expect(u.selection == .select(rows: [0..<2], detail: .count(2)))
        #expect(table.selectedPositions == [6_006, 6_009])
        #expect((table.detail, table.detailCount) == (nil, 2))

        budget.limitBytes = perEntry * (10_000 - 6_008)  // evicts 0..<6,008
        table.update()
        #expect(table.selectedPositions == [6_009])
        #expect((table.detail, table.detailCount) == (6_009, nil))

        budget.limitBytes = perEntry * (10_000 - 6_010)
        #expect(table.update().selection == .clear)
        #expect(table.viewport.selection.isEmpty)
        #expect((table.detail, table.detailCount) == (nil, nil))
    }

    /// Clear empties the selection, whatever its size.
    @Test func clearEmptiesTheSelection() async {
        let (s, table) = await streamed()
        table.selectAll()
        s.clear()
        #expect(table.update().selection == .clear)
        #expect(table.viewport.selection.isEmpty)
        #expect(table.selectedRows.isEmpty)
        #expect((table.detail, table.detailCount) == (nil, nil))
        // New rows after the clear are not selected.
        stream(10_000..<10_100)
        #expect(await settle(s, total: 10_100))
        #expect(table.update().selection == .keep)
        #expect(table.selectedRows.isEmpty)
    }

    /// Selecting (part of) rows evicted since the last update keeps the part still there; a
    /// selection made between a reset and the next update is ignored.
    @Test func selectionOfRowsEvictedSinceTheUpdate() async {
        let budget = MemoryBudget()
        let (s, table) = await streamed(budget: budget)
        let perEntry = s.store.estimatedBytes / s.store.count
        budget.limitBytes = perEntry * (s.store.count - 100)
        table.click(tableRow: 50)
        #expect(table.selectedRows.isEmpty)  // ignored
        table.click(tableRow: 90)
        table.shiftClick(tableRow: 110)
        #expect(table.viewport.selection.ranges == [100..<111])
        #expect(table.detailCount == 11)
        s.setFilter(processIs("A"))
        table.selectAll()
        #expect(table.selectedRows.isEmpty)
        #expect(table.viewport.selection.ranges == [100..<111])
    }

    /// The selection is mapped to table rows by its ranges' ends, not row by row: ⌘A over
    /// 200,000 rows, then 50 updates that each evict rows at the front, stay cheap.
    @Test func selectAllMappingIsRangeBased() async {
        let budget = MemoryBudget()
        let (s, table) = await streamed(200_000, budget: budget)
        table.selectAll()
        #expect(table.viewport.selection.ranges == [0..<200_000])
        let perEntry = s.store.estimatedBytes / s.store.count
        let clock = ContinuousClock()
        var spent = Duration.zero
        for i in 1...50 {
            budget.limitBytes = perEntry * (200_000 - i * 100)
            let started = clock.now
            let u = table.viewport.apply(s, following: false)
            spent += clock.now - started
            let count = s.rows.count
            #expect(u.selection == .select(rows: [0..<count], detail: .count(count)))
        }
        #expect(table.viewport.selection.ranges.count == 1)
        #expect(spent < .milliseconds(25), "50 updates took \(spent)")
    }

    // MARK: Copying a selection

    /// The selected rows' entries in row order, gathered in chunks of at most
    /// `maxRescanChunk`; each chunk is handed to the transform (off the main actor).
    @Test func selectedEntriesComeInChunksInRowOrder() async {
        let (s, table) = await streamed()
        table.click(tableRow: 10)
        table.shiftClick(tableRow: 2_509)
        table.commandClick(tableRow: 9_999)
        let chunks = await s.mapSelectedEntries(table.viewport.selectionForCopy) { chunk in
            chunk.map { Int($0.date.timeIntervalSince1970) }
        }
        #expect(chunks?.map(\.count) == [1_000, 1_000, 500, 1])
        #expect(chunks?.flatMap { $0 } == Array(10..<2_510) + [9_999])
    }

    /// Filtered: only the selected positions that are rows (⌘A under A spans B and C
    /// positions too); slow copies shrink the chunk.
    @Test func selectedEntriesFollowTheRowsAndShrinkSlowChunks() async {
        let (s, table) = await streamed()
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        table.selectAll()
        s.copyDurationOverride = .milliseconds(10)
        let chunks = await s.mapSelectedEntries(table.viewport.selectionForCopy) { chunk in
            chunk.map { Int($0.date.timeIntervalSince1970) }
        }
        #expect(chunks?.first?.count == 1_000)
        #expect(chunks?.dropFirst().allSatisfy { $0.count <= StreamSession.minRescanChunk } == true)
        #expect(chunks?.flatMap { $0 } == Array(stride(from: 0, to: 10_000, by: 3)))
    }

    /// Positions evicted while the copy is under way are skipped.
    @Test func selectedEntriesSkipPositionsEvictedMidCopy() async {
        let budget = MemoryBudget()
        let (s, table) = await streamed(budget: budget)
        table.selectAll()
        let perEntry = s.store.estimatedBytes / s.store.count
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            if copies == 2 { budget.limitBytes = perEntry * 5_000 }  // evicts 0..<5,000
        }
        let chunks = await s.mapSelectedEntries(table.viewport.selectionForCopy) { chunk in
            chunk.map { Int($0.date.timeIntervalSince1970) }
        }
        #expect(chunks?.flatMap { $0 } == Array(0..<2_000) + Array(5_000..<10_000))
    }

    /// A cancelled copy returns nil.
    @Test func cancelledCopyReturnsNil() async {
        let (s, table) = await streamed()
        table.selectAll()
        let task = Task { @MainActor in
            await s.mapSelectedEntries(table.viewport.selectionForCopy) { $0.count }
        }
        task.cancel()
        #expect(await task.value == nil)
    }

    /// A filter change while several rows are being copied abandons the copy: the rest would
    /// come from another filter's rows inside the old position span.
    @Test func filterChangeMidCopyAbandonsIt() async {
        let (s, table) = await streamed()
        table.selectAll()
        let selection = table.viewport.selectionForCopy
        var copies = 0
        s.afterRescanCopy = {
            copies += 1
            if copies == 2 { s.setFilter(self.processIs("A")) }
        }
        #expect(await s.mapSelectedEntries(selection) { $0.count } == nil)
    }

    /// Several rows selected under A; the filter is removed and Copy runs before the table's
    /// next update: nothing is copied (the span would cover B and C rows).
    @Test func copyBetweenAFilterChangeAndTheUpdateIsAbandoned() async {
        let (s, table) = await streamed()
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        table.update()
        table.click(tableRow: s.rows.row(forPosition: 6_000))
        table.shiftClick(tableRow: s.rows.row(forPosition: 6_009)!)
        s.setFilter(nil)
        #expect(await s.mapSelectedEntries(table.viewport.selectionForCopy) { $0.count } == nil)
    }

    /// One selected message is a single position: it stays valid across filter changes.
    @Test func singleSelectionCopiesAcrossAFilterChange() async {
        let (s, table) = await streamed()
        table.click(tableRow: 6_000)
        s.setFilter(processIs("A"))
        #expect(await settle(s, total: 10_000))
        let chunks = await s.mapSelectedEntries(table.viewport.selectionForCopy) {
            $0.map { Int($0.date.timeIntervalSince1970) }
        }
        #expect(chunks == [[6_000]])
    }
}

