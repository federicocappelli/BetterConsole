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
    /// area and which one is selected, plus what the detail pane shows.
    @MainActor final class FakeTable {
        let session: StreamSession
        let viewport = RowViewport()
        var top: Int?
        var topOffset: Double = 0
        var selected: Int?
        /// Position of the message the detail pane shows.
        var detail: Int?
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
            case .select(let row): selected = row
            case .deselect(let clearDetail):
                selected = nil
                if clearDetail { detail = nil }
            }
            viewport.recordTop(tableRow: top, offset: topOffset, in: session.rows, byUser: false)
            return u
        }

        /// The user scrolls so that table row `row` is at the top.
        func scroll(toTableRow row: Int, offset: Double = 0) {
            (top, topOffset) = (row, offset)
            viewport.recordTop(tableRow: row, offset: offset, in: session.rows, byUser: true)
        }

        /// The user clicks table row `row`.
        func click(tableRow row: Int?) {
            selected = row
            switch viewport.userSelected(tableRow: row, in: session.rows) {
            case .entry(let r): detail = session.rows.position(ofRow: r)
            case .cleared: detail = nil
            case .ignored: selected = nil
            }
        }

        /// Absolute position of the message at the top / selected, as the table shows them.
        var topPosition: Int? { top.map { session.rows.position(ofRow: $0) } }
        var selectedPosition: Int? { selected.map { session.rows.position(ofRow: $0) } }
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
        #expect(table.viewport.isSelectionShown)
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
        #expect(u.selection == .deselect(clearDetail: true))
        #expect(table.detail == nil)
        #expect(table.viewport.selectedPosition == nil)
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
        #expect(u.selection == .deselect(clearDetail: true))
        #expect(table.detail == nil)
        #expect(table.viewport.selectedPosition == nil)
    }

    @Test func evictingAShownSelectionClearsIt() async {
        let budget = MemoryBudget()
        let (s, table) = await streamed(budget: budget)
        table.click(tableRow: 100)
        let perEntry = s.store.estimatedBytes / s.store.count
        budget.limitBytes = perEntry * (s.store.count - 200)
        let u = table.update()
        #expect(u.selection == .deselect(clearDetail: true))
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
        #expect(table.viewport.selectedPosition == 6_000)
        #expect(await settle(s, total: 10_000))
        table.update()
        #expect(table.selectedPosition == 6_000)
    }
}
