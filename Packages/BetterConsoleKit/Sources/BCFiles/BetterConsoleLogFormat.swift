import Foundation
import BCModel

/// The `.log` format Save Logs writes and opening a file reads back exactly.
///
/// UTF-8 text. Line 1 is `signature`; line 2 is `# ` and the tab-separated column names; then
/// one line per entry, its values tab-separated in column order. `date` is ISO 8601 with
/// microseconds and the zone offset, `type` the level's name, `thread` `0x` hex, `extra`
/// compact JSON with sorted keys; a missing value is empty. Inside values `\\`, `\t`, `\n`
/// and `\r` stand for a backslash, tab, line feed and carriage return. Reading goes by the
/// header's names, so columns may come in any order and unknown ones are ignored.
///
/// Every `LogEntry` field round-trips except `id` (re-stamped on load) and `machTimestamp`
/// (not written). `library` is derived from the sender path; it is read only when the sender
/// path is empty.
public enum BetterConsoleLogFormat {
    public static let signature = "# BetterConsole log 1"

    public static let columns = [
        "date", "type", "process", "pid", "thread", "subsystem", "category", "library", "activity",
        "parentActivity", "eventType", "processPath", "senderPath", "message", "extra",
        "formatString", "traceID", "userID",
    ]

    /// The two header lines, without a trailing line break.
    public static let header = signature + "\n# " + columns.joined(separator: "\t")

    /// One entry's line, without a line break.
    public static func line(for entry: LogEntry, timeZone: TimeZone = .current) -> String {
        var writer = LogTimestamps.Writer(timeZone: timeZone)
        return line(for: entry, writer: &writer)
    }

    /// The lines of `entries`, joined by line breaks (no trailing one): a chunk of a file.
    public static func lines(for entries: [LogEntry], timeZone: TimeZone = .current) -> String {
        var writer = LogTimestamps.Writer(timeZone: timeZone)
        var out = ""
        out.reserveCapacity(entries.count * 256)
        for (i, entry) in entries.enumerated() {
            if i > 0 { out.append("\n") }
            out.append(line(for: entry, writer: &writer))
        }
        return out
    }

    /// A whole file from chunks of `lines(for:)`: the header, then each chunk, each followed by
    /// a line break.
    public static func fileData(_ pieces: [String]) -> Data {
        var data = Data()
        data.reserveCapacity(header.utf8.count + 1 + pieces.reduce(0) { $0 + $1.utf8.count + 1 })
        data.append(contentsOf: header.utf8)
        data.append(0x0A)
        for piece in pieces where !piece.isEmpty {
            data.append(contentsOf: piece.utf8)
            data.append(0x0A)
        }
        return data
    }

    private static func line(for e: LogEntry, writer: inout LogTimestamps.Writer) -> String {
        var s = writer.string(from: e.date)
        func field(_ value: String?) {
            s.append("\t")
            if let value { s.append(escape(value)) }
        }
        func number<T: BinaryInteger>(_ value: T?) {
            s.append("\t")
            if let value { s.append(String(value)) }
        }
        field(e.level.rawValue)
        field(e.process)
        number(e.pid)
        s.append("\t")
        if let thread = e.threadID { s.append("0x" + String(thread, radix: 16)) }
        field(e.subsystem)
        field(e.category)
        field(e.senderImagePath.map(lastPathComponent))
        number(e.activityID)
        number(e.parentActivityID)
        field(e.eventType)
        field(e.processImagePath)
        field(e.senderImagePath)
        field(e.message)
        field(e.extra.isEmpty ? nil : json(e.extra))
        field(e.formatString)
        number(e.traceID)
        number(e.userID)
        return s
    }

    // MARK: Escaping

    public static func escape(_ value: String) -> String {
        guard value.utf8.contains(where: { $0 == 0x5C || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
        else { return value }
        var out = [UInt8]()
        out.reserveCapacity(value.utf8.count + 8)
        for b in value.utf8 {
            switch b {
            case 0x5C: out += [0x5C, 0x5C]
            case 0x09: out += [0x5C, UInt8(ascii: "t")]
            case 0x0A: out += [0x5C, UInt8(ascii: "n")]
            case 0x0D: out += [0x5C, UInt8(ascii: "r")]
            default: out.append(b)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The inverse of `escape`; a lone or unknown escape is kept as is.
    public static func unescape(_ value: String) -> String {
        var copy = value
        return copy.withUTF8 { unescape($0) }
    }

    static func unescape(_ b: UnsafeBufferPointer<UInt8>) -> String {
        guard b.contains(0x5C) else { return String(decoding: b, as: UTF8.self) }
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 0x5C, i + 1 < b.count {
                let n = b[i + 1]
                let mapped: UInt8? =
                    switch n {
                    case 0x5C: 0x5C
                    case UInt8(ascii: "t"): 0x09
                    case UInt8(ascii: "n"): 0x0A
                    case UInt8(ascii: "r"): 0x0D
                    default: nil
                    }
                if let mapped {
                    out.append(mapped)
                    i += 2
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Extra as JSON

    static func json(_ extra: [String: JSONValue]) -> String {
        let object = extra.mapValues(foundationValue)
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        case .array(let a): a.map(foundationValue)
        case .object(let o): o.mapValues(foundationValue)
        }
    }

    static func jsonValue(_ any: Any) -> JSONValue {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: return .array(a.map(jsonValue))
        case let o as [String: Any]: return .object(o.mapValues(jsonValue))
        default: return .null
        }
    }

    static func lastPathComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    // MARK: Reading

    /// Reads entry lines by the column names of the header's second line.
    struct Reader {
        private enum Column {
            case date, type, process, pid, thread, subsystem, category, library, activity
            case parentActivity, eventType, processPath, senderPath, message, extra
            case formatString, traceID, userID, unknown
        }

        private let columns: [Column]
        private let timeZone: TimeZone

        /// `header`: the second line, `# ` and tab-separated names.
        init(header: UnsafeBufferPointer<UInt8>, timeZone: TimeZone) {
            var start = 0
            if header.count >= 2, header[0] == UInt8(ascii: "#"), header[1] == 0x20 { start = 2 }
            let names = String(decoding: UnsafeBufferPointer(rebasing: header[start...]), as: UTF8.self)
                .split(separator: "\t", omittingEmptySubsequences: false)
            columns = names.map { name in
                switch name {
                case "date": .date
                case "type": .type
                case "process": .process
                case "pid": .pid
                case "thread": .thread
                case "subsystem": .subsystem
                case "category": .category
                case "library": .library
                case "activity": .activity
                case "parentActivity": .parentActivity
                case "eventType": .eventType
                case "processPath": .processPath
                case "senderPath": .senderPath
                case "message": .message
                case "extra": .extra
                case "formatString": .formatString
                case "traceID": .traceID
                case "userID": .userID
                default: .unknown
                }
            }
            self.timeZone = timeZone
        }

        /// The default header (a file whose second line is missing).
        init(timeZone: TimeZone) {
            var text = "# " + BetterConsoleLogFormat.columns.joined(separator: "\t")
            self = text.withUTF8 { Reader(header: $0, timeZone: timeZone) }
        }

        func entry(_ b: UnsafeBufferPointer<UInt8>, id: UInt64, fallbackDate: Date, fileName: String)
            -> LogEntry
        {
            var date: Date?
            var level = LogLevel.default
            var process = ""
            var pid: Int32?
            var thread: UInt64?
            var subsystem: String?
            var category: String?
            var library: String?
            var activity: UInt64?
            var parentActivity: UInt64?
            var eventType = ""
            var processPath: String?
            var senderPath: String?
            var message = ""
            var extra: [String: JSONValue] = [:]
            var formatString: String?
            var traceID: UInt64?
            var userID: UInt32?

            var column = 0
            var start = 0
            var i = 0
            while i <= b.count {
                guard i == b.count || b[i] == 0x09 else {
                    i += 1
                    continue
                }
                if column < columns.count, i > start {
                    let value = UnsafeBufferPointer(rebasing: b[start..<i])
                    switch columns[column] {
                    case .date:
                        date = LogTimestamps.parseISO(value, at: 0, timeZone: timeZone)
                            .map { Date(timeIntervalSince1970: $0.seconds) }
                    case .type: level = LogLevel(messageType: string(value))
                    case .process: process = unescape(value)
                    case .pid: pid = Int32(string(value))
                    case .thread:
                        var c = ByteCursor(value)
                        thread = c.hex() ?? UInt64(string(value))
                    case .subsystem: subsystem = unescape(value)
                    case .category: category = unescape(value)
                    case .library: library = unescape(value)
                    case .activity: activity = UInt64(string(value))
                    case .parentActivity: parentActivity = UInt64(string(value))
                    case .eventType: eventType = unescape(value)
                    case .processPath: processPath = unescape(value)
                    case .senderPath: senderPath = unescape(value)
                    case .message: message = unescape(value)
                    case .extra:
                        let text = unescape(value)
                        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                            as? [String: Any]
                        {
                            extra = object.mapValues(BetterConsoleLogFormat.jsonValue)
                        }
                    case .formatString: formatString = unescape(value)
                    case .traceID: traceID = UInt64(string(value))
                    case .userID: userID = UInt32(string(value))
                    case .unknown: break
                    }
                }
                column += 1
                i += 1
                start = i
            }
            return LogEntry(
                id: id, date: date ?? fallbackDate, level: level, eventType: eventType,
                process: process, processImagePath: processPath, pid: pid, threadID: thread,
                subsystem: subsystem, category: category, message: message,
                formatString: formatString, senderImagePath: senderPath ?? library,
                activityID: activity, parentActivityID: parentActivity, traceID: traceID,
                userID: userID, extra: extra)
        }

        private func string(_ b: UnsafeBufferPointer<UInt8>) -> String {
            String(decoding: b, as: UTF8.self)
        }
    }
}
