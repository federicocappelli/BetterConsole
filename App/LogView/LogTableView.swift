import AppKit
import Observation
import SwiftUI
import BCFilter
import BCModel
import BCStore
import BCStreaming

/// View-based `NSTableView` over `session.rows` (every stored message, or only the matching
/// ones), with the detail pane below it in an `NSSplitView` (SwiftUI's `VSplitView` cannot set
/// the initial 70/30 divider position).
/// The data source reads the rows directly. The coordinator observes `session.revision`
/// itself (SwiftUI only forwards Now requests) and applies updates at most every
/// `Coordinator.minUpdateInterval`.
struct LogTableView: NSViewRepresentable {
    let session: StreamSession
    /// The right-click Hide/Show items edit this device's filter through it.
    let workspace: FilterWorkspace
    /// Bumped by the Now button: scroll to the bottom and follow again.
    let nowRequest: Int
    /// Called with the selected entry, or nil when the selection is cleared or evicted.
    let onSelect: @MainActor (LogEntry?) -> Void
    /// Shown in the lower pane.
    let detail: LogDetailView

    static let rowHeight: CGFloat = 18
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(session: session, workspace: workspace) }

    func makeNSView(context: Context) -> NSSplitView {
        let table = LogNSTableView()
        table.usesAutomaticRowHeights = false
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        for column in LogColumn.defaultColumns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.style == .levelSymbol ? 24 : 40
            tableColumn.resizingMask = [.userResizingMask, .autoresizingMask]
            table.addTableColumn(tableColumn)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let detailHost = NSHostingView(rootView: detail)
        let split = LogSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scrollView)
        split.addArrangedSubview(detailHost)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        // Columns were added at zero width: let Message fill what the others leave, after
        // which `.lastColumnOnlyAutoresizingStyle` keeps it filling on resize.
        split.onFirstLayout = { [weak table] in table?.sizeLastColumnToFit() }

        context.coordinator.attach(table: table, scrollView: scrollView)
        context.coordinator.observeRevision()
        context.coordinator.detailHost = detailHost
        context.coordinator.onSelect = onSelect
        table.menuForRow = { [coordinator = context.coordinator] row in coordinator.menu(forRow: row) }
        table.copySelectedRow = { [coordinator = context.coordinator] in coordinator.copySelectedRow() }
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.workspace = workspace
        if let host = context.coordinator.detailHost, host.rootView != detail {
            host.rootView = detail
        }
        context.coordinator.requestUpdate(nowRequest: nowRequest)
    }

    /// Fill whatever is offered. Without this SwiftUI measures the split view's fitting size
    /// (including the detail pane's SwiftUI content) on every SwiftUI update.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }

    static func dismantleNSView(_ split: NSSplitView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        /// The drain runs every 100 ms; faster revision bumps (evictions) are coalesced.
        static let minUpdateInterval: Duration = .milliseconds(100)

        let session: StreamSession
        var workspace: FilterWorkspace
        var onSelect: @MainActor (LogEntry?) -> Void = { _ in }
        var detailHost: NSHostingView<LogDetailView>?

        private weak var table: NSTableView?
        private weak var scrollView: NSScrollView?
        private let columns: [String: LogColumn] = Dictionary(
            uniqueKeysWithValues: LogColumn.defaultColumns.map { ($0.id, $0) })

        /// Row mapping, top anchor and selection over `session.rows` (the decisions; this
        /// coordinator applies them to the table).
        private let viewport = RowViewport()
        private var appliedRevision = -1
        /// The clip view's origin when the last update finished: a bounds change that moves
        /// it outside an update is the user's (scroll, resize).
        private var appliedOriginY: CGFloat?

        /// Auto-scroll to the newest row on every update.
        private var followTracker = FollowTracker()
        private var isFollowing: Bool {
            get { followTracker.isFollowing }
            set { followTracker.isFollowing = newValue }
        }
        private var isLiveScrolling = false
        private var scrollToBottomRequested = false
        private var lastNowRequest: Int?
        /// Set while the coordinator changes the table itself, to ignore its own echoes.
        private var isApplying = false

        private var lastApply: ContinuousClock.Instant?
        private var pendingUpdate: Task<Void, Never>?
        private var isDetached = false

        init(session: StreamSession, workspace: FilterWorkspace) {
            self.session = session
            self.workspace = workspace
        }

        func attach(table: NSTableView, scrollView: NSScrollView) {
            self.table = table
            self.scrollView = scrollView
            table.dataSource = self
            table.delegate = self

            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(willStartLiveScroll),
                name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            center.addObserver(
                self, selector: #selector(didLiveScroll),
                name: NSScrollView.didLiveScrollNotification, object: scrollView)
            center.addObserver(
                self, selector: #selector(didEndLiveScroll),
                name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            scrollView.contentView.postsBoundsChangedNotifications = true
            center.addObserver(
                self, selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }

        func detach() {
            isDetached = true
            pendingUpdate?.cancel()
            pendingUpdate = nil
            NotificationCenter.default.removeObserver(self)
        }

        /// Schedules an update on every `revision` change (re-registering each time, as
        /// observation tracking fires once).
        func observeRevision() {
            guard !isDetached else { return }
            withObservationTracking {
                _ = session.revision
            } onChange: { [weak self] in
                // Called before the change is stored: act on the next main-actor turn.
                Task { @MainActor [weak self] in
                    self?.observeRevision()
                    self?.scheduleUpdate()
                }
            }
        }

        // MARK: Updates

        func requestUpdate(nowRequest: Int) {
            if let lastNowRequest, lastNowRequest != nowRequest {
                isFollowing = true
                scrollToBottomRequested = true
            }
            lastNowRequest = nowRequest
            guard scrollToBottomRequested || session.revision != appliedRevision else { return }
            scheduleUpdate()
        }

        /// Applies on the next main-actor turn (never inside a SwiftUI view update), at most
        /// once per `minUpdateInterval`; requests in between coalesce into the pending one.
        private func scheduleUpdate() {
            guard pendingUpdate == nil, !isDetached else { return }
            var delay = Duration.zero
            if let lastApply {
                delay = max(.zero, Self.minUpdateInterval - (ContinuousClock.now - lastApply))
            }
            pendingUpdate = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self else { return }
                self.pendingUpdate = nil
                self.apply()
            }
        }

        private func apply() {
            guard let table, let scrollView else { return }
            let started = ContinuousClock.now
            defer { MainThreadProbe.recordUpdate(.now - started) }
            lastApply = started
            let follow = (isFollowing && !isLiveScrolling) || scrollToBottomRequested
            let clip = scrollView.contentView

            isApplying = true
            defer {
                isApplying = false
                // Whatever the update did to the scroll position is ours, not the user's.
                if let geometry { self.followTracker.recordOwnChange(geometry) }
                recordTop(byUser: false)
                appliedOriginY = clip.bounds.minY
            }

            appliedRevision = session.revision
            let update = viewport.apply(session, following: follow)
            let count = update.count

            // Indices shifted (rows added or removed at the front, or all replaced): the
            // viewport says which row to select and which message to keep at the top; the
            // rows that have views are refreshed (`reloadRowsWithViews`). `reloadData()`
            // rebuilt every row view, ~5 ms per update while the budget evicts on every drain;
            // `removeRows` at the front plus `insertRows` at the end kept the surviving views
            // but cost ~4 ms per update with 800k rows. A reset replaced every row: reload.
            switch update.reload {
            case .all: table.reloadData()
            case .numberOfRows: table.noteNumberOfRowsChanged()
            case .none: break
            }
            switch update.selection {
            case .keep:
                break
            case .select(let row):
                table.selectRowIndexes([row], byExtendingSelection: false)
            case .deselect(let clearDetail):
                table.deselectAll(nil)
                if clearDetail { onSelect(nil) }
            }
            if !follow, let target = update.scroll {
                var y: CGFloat = 0
                if case .row(let row, let offset) = target {
                    y = table.rect(ofRow: row).minY + CGFloat(offset)
                }
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y - clip.contentInsets.top))
                scrollView.reflectScrolledClipView(clip)
            }

            if follow && count > 0 {
                table.scrollRowToVisible(count - 1)
            }
            if update.refreshRowsWithViews {
                reloadRowsWithViews(in: table)
            }
            scrollToBottomRequested = false
        }

        /// Re-fetches the cells of every row that currently has a view (visible rows plus
        /// whatever the table has prepared around them); rows without one are fetched fresh
        /// when they appear.
        private func reloadRowsWithViews(in table: NSTableView) {
            var rows = IndexSet()
            table.enumerateAvailableRowViews { _, row in
                if row >= 0 { rows.insert(row) }
            }
            guard !rows.isEmpty else { return }
            table.reloadData(
                forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }

        /// The entry the table's `row` shows, or nil (blank) if it is no longer a row.
        private func entry(forRow row: Int) -> LogEntry? {
            viewport.currentRow(forTableRow: row, in: session.rows).map { session.rows[$0] }
        }

        // MARK: Context menu and Copy

        /// Copy, Copy Message, then Hide … and Show … items for the values of the row. The
        /// table has already selected the row (through the normal selection path).
        func menu(forRow row: Int) -> NSMenu? {
            guard let entry = entry(forRow: row) else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            // A closure item, not `copy:` through the responder chain: a right-click does not
            // make the table first responder, so another field's `copy:` could run instead.
            let copy = ClosureMenuItem(title: "Copy") { [weak self] in self?.copySelectedRow() }
            copy.keyEquivalent = "c"
            copy.keyEquivalentModifierMask = .command
            menu.addItem(copy)
            menu.addItem(ClosureMenuItem(title: "Copy Message") { [weak self] in
                self?.copy(RowCopy.message(of: entry))
            })
            let items = QuickFilterItems.items(for: entry)
            for include in [false, true] where !items.isEmpty {
                menu.addItem(.separator())
                for item in items {
                    let verb = include ? "Show" : "Hide"
                    let title = "\(verb) \(item.condition.field.title) '\(item.menuValue)'"
                    menu.addItem(ClosureMenuItem(title: title) { [weak self] in
                        self?.addBubble(item.condition, include: include)
                    })
                }
            }
            return menu
        }

        func copySelectedRow() {
            guard let table, table.selectedRow >= 0, let entry = entry(forRow: table.selectedRow)
            else { return }
            copy(RowCopy.line(for: entry, columns: LogColumn.defaultColumns))
        }

        private func copy(_ string: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        }

        private func addBubble(_ condition: FilterCondition, include: Bool) {
            let id = session.device.id
            let bubbles = BubbleEditing.adding(
                condition, include: include,
                to: BubbleCodec.bubbles(from: workspace.state(for: id).expression))
            workspace.setExpression(BubbleCodec.expression(from: bubbles), for: id)
        }

        /// Tells the viewport which message is at the top of the visible area.
        private func recordTop(byUser: Bool) {
            guard let table, let scrollView else { return }
            let clip = scrollView.contentView
            let topY = clip.bounds.minY + clip.contentInsets.top
            let topRow = table.row(at: NSPoint(x: 0, y: max(0, topY)))
            viewport.recordTop(
                tableRow: topRow >= 0 ? topRow : nil,
                offset: topRow >= 0 ? Double(topY - table.rect(ofRow: topRow).minY) : 0,
                in: session.rows, byUser: byUser)
        }

        /// The clip view's current geometry, for `FollowTracker`.
        private var geometry: FollowTracker.Geometry? {
            guard let table, let scrollView else { return nil }
            let clip = scrollView.contentView
            return FollowTracker.Geometry(
                originY: clip.bounds.minY, clipSize: clip.bounds.size,
                documentHeight: table.frame.height, isAtBottom: isAtBottom)
        }

        private var isAtBottom: Bool {
            guard let table, let scrollView else { return true }
            let clip = scrollView.contentView
            return clip.bounds.maxY >= table.frame.height + clip.contentInsets.bottom
                - LogTableView.rowHeight / 2
        }

        // MARK: Scrolling

        @objc private func willStartLiveScroll(_ notification: Notification) {
            isLiveScrolling = true
        }

        @objc private func didLiveScroll(_ notification: Notification) {
            // Scrolling away from the bottom stops following; back to the bottom resumes it.
            isFollowing = isAtBottom
        }

        @objc private func didEndLiveScroll(_ notification: Notification) {
            isLiveScrolling = false
            isFollowing = isAtBottom
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard let geometry else { return }
            // Our own scrolling (apply) and live scrolls (handled above) are only recorded.
            // Anything else is a wheel, keyboard or resize change: scrolling up stops
            // following, reaching the bottom resumes it (see FollowTracker).
            if isApplying || isLiveScrolling {
                followTracker.recordOwnChange(geometry)
            } else {
                followTracker.boundsChanged(geometry)
            }
            // `apply` records the top once it is done.
            if !isApplying {
                let moved = appliedOriginY.map { abs($0 - geometry.originY) >= 0.5 } ?? true
                recordTop(byUser: isLiveScrolling || moved)
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int { viewport.shownCount }

        // MARK: NSTableViewDelegate

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard let tableColumn, let column = columns[tableColumn.identifier.rawValue] else {
                return nil
            }
            let entry = entry(forRow: row)

            switch column.style {
            case .text:
                // Identifiers map to one cell class each, so the reused view's class is known.
                let cell =
                    tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
                    .map { unsafeDowncast($0, to: LogTextCellView.self) }
                    ?? LogTextCellView(identifier: tableColumn.identifier)
                cell.cachesLines = column.cachesLines
                cell.text = entry.map(column.value) ?? ""
                return cell
            case .levelSymbol:
                let cell =
                    tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
                    .map { unsafeDowncast($0, to: LevelSymbolCellView.self) }
                    ?? LevelSymbolCellView(identifier: tableColumn.identifier)
                cell.level = entry?.level
                cell.setAccessibilityLabel(entry.map(column.value))
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            tableView.makeView(withIdentifier: LogRowView.reuseIdentifier, owner: nil)
                .map { unsafeDowncast($0, to: LogRowView.self) } ?? LogRowView()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table else { return }
            let row = table.selectedRow
            switch viewport.userSelected(tableRow: row >= 0 ? row : nil, in: session.rows) {
            case .entry(let current):
                // Keep the selected row on screen instead of following new messages.
                isFollowing = false
                onSelect(session.rows[current])
            case .cleared:
                onSelect(nil)
            case .ignored:
                // A row replaced since the last update (blank): undo the click, keep the detail.
                isApplying = true
                table.deselectAll(nil)
                isApplying = false
            }
        }
    }
}

// MARK: - Table

/// Adds the row context menu (selecting the clicked row first) and ⌘C to `NSTableView`.
final class LogNSTableView: NSTableView {
    /// The menu for the clicked row (already selected), or nil for none.
    var menuForRow: (Int) -> NSMenu? = { _ in nil }
    /// Copies the selected row.
    var copySelectedRow: () -> Void = {}

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) || selectedRowIndexes.count != 1 {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return menuForRow(row)
    }

    @objc func copy(_ sender: Any?) { copySelectedRow() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

// MARK: - Split

/// Puts the divider at 70 % of the height (detail pane 30 %) on the first real layout; the
/// user's position is kept from then on.
final class LogSplitView: NSSplitView {
    private var didSetInitialPosition = false
    /// Runs once after the first real layout.
    var onFirstLayout: () -> Void = {}

    override func layout() {
        super.layout()
        guard !didSetInitialPosition, bounds.height > 0 else { return }
        didSetInitialPosition = true
        setPosition((bounds.height * 0.7).rounded(), ofDividerAt: 0)
        onFirstLayout()
    }
}

// MARK: - Cells

/// Draws its cells into its own layer: one backing store per row instead of one per cell,
/// which matters while following, when every visible row is redrawn on each update.
final class LogRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("LogRow")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        canDrawSubviewsIntoLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Single-line, tail-truncated text in the table font, drawn with Core Text. An `NSTextField`
/// per cell (string value, appearance provider, own layer) costs several times more while
/// following, when every visible cell changes on each update.
final class LogTextCellView: NSTableCellView {
    var text = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }

    /// Reuse typeset lines across rows; for columns whose values repeat (process, subsystem).
    var cachesLines = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }

    override func accessibilityValue() -> Any? { text }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        var line = cachesLines ? LineCache.shared.line(for: text) : LineCache.makeLine(text, width: width)
        if line.width > width {
            guard let truncated = CTLineCreateTruncatedLine(
                line.line, Double(width), .end, LineCache.shared.ellipsis)
            else { return }
            line.line = truncated
        }
        (backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : .labelColor)
            .setFill()
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        let font = LogTableView.font
        let lineHeight = font.ascender - font.descender
        let top = ((bounds.height - lineHeight) / 2).rounded(.down)
        if isFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        // Baseline measured from the bottom edge in unflipped coordinates.
        context.textPosition = CGPoint(x: 0, y: (bounds.height - top - font.ascender).rounded())
        CTLineDraw(line.line, context)
    }
}

/// Typesets single lines in the table font, colored from the context's fill color so a line
/// draws in any selection state. Main-actor only (cells draw on the main thread).
@MainActor
final class LineCache {
    static let shared = LineCache()
    private static let limit = 4_096
    private static let attributes = NSDictionary(dictionary: [
        kCTFontAttributeName: LogTableView.font,
        kCTForegroundColorFromContextAttributeName: true,
    ]) as! [NSAttributedString.Key: Any]

    struct Line {
        var line: CTLine
        let width: CGFloat
    }

    let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
    private var lines: [String: Line] = [:]

    func line(for text: String) -> Line {
        if let line = lines[text] { return line }
        if lines.count >= Self.limit { lines.removeAll(keepingCapacity: true) }
        let line = Self.makeLine(text, width: nil)
        lines[text] = line
        return line
    }

    /// Average glyph advance of the table font over typical log text.
    private static let averageAdvance: CGFloat = {
        let sample = "Process: <private> with state 0x7c4 lookupHandle [com.apple] 1234567890"
        return typeset(sample).width / CGFloat(sample.count)
    }()

    /// With a `width`, only about as many characters as fit are typeset, estimated from the
    /// average advance with a margin. If that prefix still comes out narrower than `width`
    /// (narrow glyphs), it is doubled until it overflows or the text runs out, so a line that
    /// overflows the cell always keeps its ellipsis.
    static func makeLine(_ text: String, width: CGFloat?) -> Line {
        guard let width else { return typeset(text) }
        var characters = Int(width / averageAdvance * 1.25) + 4
        while true {
            // `utf8.count` is O(1); a string with fewer bytes has fewer characters.
            guard text.utf8.count > characters else { return typeset(text) }
            let prefix = text.prefix(characters)
            if prefix.endIndex == text.endIndex { return typeset(text) }
            let line = typeset(String(prefix))
            if line.width > width { return line }
            characters *= 2
        }
    }

    private static func typeset(_ text: String) -> Line {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return Line(line: line, width: CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// The Type column: a colored dot for the entry's level.
final class LevelSymbolCellView: NSTableCellView {
    private static let pointSize: CGFloat = 12

    /// One rendered image per level, built once: drawing a cached image keeps the cell as cheap
    /// as the old dot under heavy scrolling.
    @MainActor private static var images: [LogLevel: NSImage] = [:]

    private static func image(for level: LogLevel) -> NSImage? {
        if let cached = images[level] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [level.symbolColor]))
        let image = NSImage(systemSymbolName: level.symbolName, accessibilityDescription: level.rawValue)?
            .withSymbolConfiguration(config)
        images[level] = image
        return image
    }

    var level: LogLevel? {
        didSet { if level != oldValue { needsDisplay = true } }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let level, let image = Self.image(for: level) else { return }
        let size = image.size
        let rect = NSRect(
            x: floor((bounds.width - size.width) / 2), y: floor((bounds.height - size.height) / 2),
            width: size.width, height: size.height)
        image.draw(in: rect)
    }
}

