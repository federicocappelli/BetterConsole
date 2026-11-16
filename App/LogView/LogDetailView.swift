import SwiftUI
import BCModel

/// The lower pane: the selected entry's full message, then every non-nil field and each
/// `extra` key (sorted). All text is selectable. With several rows selected, their count.
struct LogDetailView: View, Equatable {
    enum Content: Equatable {
        case none
        case entry(LogEntry)
        /// Several rows are selected.
        case several(Int)

        /// Entries are immutable, so their key decides equality.
        nonisolated static func == (lhs: Content, rhs: Content) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none): true
            case (.entry(let a), .entry(let b)): EntryKey(a) == EntryKey(b)
            case (.several(let a), .several(let b)): a == b
            default: false
            }
        }
    }

    let content: Content

    /// Content decides redraws; the pane is not rebuilt on every table update.
    nonisolated static func == (lhs: LogDetailView, rhs: LogDetailView) -> Bool {
        lhs.content == rhs.content
    }

    var body: some View {
        switch content {
        case .entry(let entry):
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.message)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                        ForEach(Array(Self.fields(of: entry).enumerated()), id: \.offset) { _, field in
                            GridRow {
                                Text(field.name)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(field.value)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(.system(size: 11))
                }
                .padding(10)
                .textSelection(.enabled)
            }
            .background(.background)
        case .several(let count):
            Text("\(count.formatted()) messages selected")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        case .none:
            Text("Select a message to see its details")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
    }

    struct Field {
        let name: String
        let value: String
    }

    @MainActor private static let dateFormatter = LogTimestampFormatter(dateFormat: "yyyy-MM-dd HH:mm:ss")

    /// Every non-nil typed field, then each `extra` key in sorted order.
    @MainActor static func fields(of entry: LogEntry) -> [Field] {
        var fields: [Field] = []
        func add(_ name: String, _ value: String?) {
            if let value { fields.append(Field(name: name, value: value)) }
        }
        let zone = TimeZone.current.abbreviation(for: entry.date) ?? TimeZone.current.identifier
        add("Date", dateFormatter.string(from: entry.date) + " " + zone)
        add("Type", entry.level.rawValue)
        add("Event Type", entry.eventType)
        add("Process", entry.process)
        add("PID", entry.pid.map(String.init))
        add("Process Path", entry.processImagePath)
        add("Thread", entry.threadID.map { "0x" + String($0, radix: 16) })
        add("Subsystem", entry.subsystem)
        add("Category", entry.category)
        add("Library", entry.senderImagePath)
        add("Format String", entry.formatString)
        add("Activity ID", entry.activityID.map(String.init))
        add("Parent Activity ID", entry.parentActivityID.map(String.init))
        add("Trace ID", entry.traceID.map(String.init))
        add("User ID", entry.userID.map(String.init))
        add("Mach Timestamp", entry.machTimestamp.map(String.init))
        for key in entry.extra.keys.sorted() {
            add(key, entry.extra[key].map { render($0, quoted: false) })
        }
        return fields
    }

    /// Compact JSON-like text; top-level strings are shown without quotes.
    static func render(_ value: JSONValue, quoted: Bool = true) -> String {
        switch value {
        case .string(let s):
            return quoted ? "\"\(s)\"" : s
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .bool(let b):
            return String(b)
        case .null:
            return "null"
        case .array(let items):
            return "[" + items.map { render($0) }.joined(separator: ", ") + "]"
        case .object(let object):
            let pairs = object.keys.sorted().map { "\"\($0)\": " + render(object[$0]!) }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }
}

/// Identifies the shown entry for redraw decisions. `LogEntry.id` is unique only within one
/// session (each device numbers from 1), so the date is part of the key.
struct EntryKey: Equatable {
    let id: UInt64
    let date: Date

    init(_ entry: LogEntry) {
        id = entry.id
        date = entry.date
    }
}
