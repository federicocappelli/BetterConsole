import AppKit
import BCModel

/// One table column. The table is built by iterating `LogColumn.defaultColumns`; no cell is
/// hard-coded, so columns can be customised later.
struct LogColumn: Identifiable, Sendable {
    enum Style: Sendable {
        /// Plain single-line text from `value`.
        case text
        /// A coloured SF Symbol for `LogEntry.level`; `value` becomes the tooltip.
        case levelSymbol
    }

    let id: String
    let title: String
    let width: CGFloat
    let style: Style
    /// Values repeat across rows (process, subsystem, ...), so typeset text is cached.
    let cachesLines: Bool
    /// The cell's text (the tooltip for a symbol), with `formatter` for timestamps. The one
    /// source for both the cell and what Copy puts on the pasteboard; safe off the main actor
    /// with a formatter of its own.
    let text: @Sendable (LogEntry, LogTimestampFormatter) -> String

    init(
        id: String, title: String, width: CGFloat, style: Style = .text, cachesLines: Bool = false,
        text: @escaping @Sendable (LogEntry, LogTimestampFormatter) -> String
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.style = style
        self.cachesLines = cachesLines
        self.text = text
    }

    /// The cell's text, timestamps with the table's formatter.
    @MainActor func value(_ entry: LogEntry) -> String { text(entry, .shared) }

    /// Time(150), Type(40, symbol), Process(140), Subsystem(200), Category(140), Message(flexible:
    /// the last column takes the remaining width).
    static let defaultColumns: [LogColumn] = [
        LogColumn(id: "time", title: "Time", width: 150) { $1.string(from: $0.date) },
        LogColumn(id: "type", title: "Type", width: 40, style: .levelSymbol) { e, _ in e.level.rawValue },
        LogColumn(id: "process", title: "Process", width: 140, cachesLines: true) { e, _ in e.process },
        LogColumn(id: "subsystem", title: "Subsystem", width: 200, cachesLines: true) { e, _ in
            e.subsystem ?? ""
        },
        LogColumn(id: "category", title: "Category", width: 140, cachesLines: true) { e, _ in
            e.category ?? ""
        },
        LogColumn(id: "message", title: "Message", width: 250) { e, _ in firstLine(of: e.message) },
    ]

    /// Longest message prefix (UTF-8 bytes) a cell gets; wider than any cell can show. The
    /// detail pane shows the full message.
    static let maxCellBytes = 1_024

    /// The first line of `message`, capped at `maxCellBytes`. Scans UTF-8 bytes (CR and LF
    /// are single bytes that never occur inside a multi-byte sequence), not characters.
    static func firstLine(of message: String) -> String {
        let utf8 = message.utf8
        let head = utf8.prefix(maxCellBytes)
        if let newline = head.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            return String(message[..<newline])
        }
        guard head.endIndex != utf8.endIndex else { return message }
        // Indices that split a scalar round down to the scalar boundary.
        return String(message[..<head.endIndex]) + "…"
    }
}

extension LogTimestampFormatter {
    /// The table's formatter, in the current time zone.
    @MainActor static let shared = LogTimestampFormatter()
}

extension LogLevel {
    /// The Type column's SF Symbol: one `.circle` symbol per level.
    var symbolName: String {
        switch self {
        case .default: "circle"
        case .info: "info.circle"
        case .debug: "ladybug.circle"
        case .error: "exclamationmark.circle"
        case .fault: "xmark.circle"
        }
    }

    /// The Type column's symbol colour: default grey, info blue, debug purple, error yellow,
    /// fault red.
    var symbolColor: NSColor {
        switch self {
        case .default: .systemGray
        case .info: .systemBlue
        case .debug: .systemPurple
        case .error: .systemYellow
        case .fault: .systemRed
        }
    }
}
