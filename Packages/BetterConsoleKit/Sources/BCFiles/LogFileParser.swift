import Foundation
import BCModel

/// Turns the lines of a text log file into entries, best effort, never failing the file.
///
/// A file starting with `BetterConsoleLogFormat.signature` is read exactly. Any other file is
/// read line by line, each line tried against the styles below (the style of the previous
/// parsed line first):
/// - NDJSON from `log stream/show --style ndjson` (lines starting with `{`);
/// - `log show`/`log stream` default style, compact style and syslog style;
/// - classic syslog (`Nov 16 21:45:31 host process[123] <Notice>: message`);
/// - generic: a leading timestamp (ISO 8601 with `T` or a space, with or without fraction and
///   zone, or a time alone for today), then an optional level word (bracketed, followed by a
///   colon, or in capitals), an optional `process[pid]`
///   or `process:` and an optional `[subsystem:category]` before the message.
///
/// A line with no recognisable timestamp continues the previous entry's message (joined with
/// a line break; blank and dash lines included, trailing blank lines dropped); lines before the
/// first entry become entries of their own, dated with the file's modification date. `log`'s
/// header, notes and end summary are skipped (dash lines only before the first entry). A JSON
/// line is `log`'s NDJSON when it looks like it and its timestamp parses, otherwise a generic
/// JSON log object (`GenericJSON`), otherwise text. A UTF-8 BOM is ignored; a file with no LF
/// breaks lines at CR. Messages are capped (`maxMessageLines`, `maxMessageBytes`). An unknown
/// process is the file's name.
public struct LogFileParser {
    public let fileName: String
    /// A message holds at most this many lines and bytes; past either, it goes on in a new
    /// entry with the same date and fields. A single longer line is cut and ends with "…".
    public static let maxMessageLines = 10_000
    public static let maxMessageBytes = 1 << 20
    private let modificationDate: Date
    private let now: Date
    private let timeZone: TimeZone

    private var lineNumber = 0
    private var nextID: UInt64 = 1
    private var bcReader: BetterConsoleLogFormat.Reader?
    /// True once line 1 turned out to be the BetterConsole signature.
    private var isBetterConsole = false
    private var ndjson = LogEntryDecoder()
    private var preferred = Style.logDefault
    /// The last entry, waiting for continuation lines.
    private var pending: LogEntry?
    private var continuation: [String] = []
    /// UTF-8 length of the pending message so far (its first line and continuations).
    private var pendingBytes = 0
    /// True once a line feed was seen; until then a bare CR breaks lines (old Mac files).
    public private(set) var sawLineFeed = false
    private var output: [LogEntry] = []

    enum Style: CaseIterable {
        case logDefault, logCompact, logSyslog, syslog, columns, generic
    }

    public init(
        fileName: String, modificationDate: Date = .now, now: Date = .now,
        timeZone: TimeZone = .current
    ) {
        self.fileName = fileName
        self.modificationDate = modificationDate
        self.now = now
        self.timeZone = timeZone
    }

    /// Parses a whole file.
    public static func parse(
        _ data: Data, fileName: String, modificationDate: Date = .now, now: Date = .now,
        timeZone: TimeZone = .current
    ) -> [LogEntry] {
        var parser = LogFileParser(
            fileName: fileName, modificationDate: modificationDate, now: now, timeZone: timeZone)
        var entries = data.withUnsafeBytes { raw in
            parser.feed(raw.bindMemory(to: UInt8.self))
        }
        entries += parser.finish()
        return entries
    }

    /// Feeds whole lines (bytes after the last line break count as a line) and returns the
    /// entries completed so far. The last entry is held back until `finish()` or the next line
    /// with a timestamp, since following lines may continue its message.
    public mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> [LogEntry] {
        var start = 0
        if let base = bytes.baseAddress {
            if !sawLineFeed, memchr(base, 0x0A, bytes.count) != nil { sawLineFeed = true }
            let separator: Int32 = sawLineFeed ? 0x0A : 0x0D
            while start < bytes.count,
                let found = memchr(base + start, separator, bytes.count - start)
            {
                let i = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                line(UnsafeBufferPointer(rebasing: bytes[start..<i]))
                start = i + 1
            }
        }
        if start < bytes.count {
            line(UnsafeBufferPointer(rebasing: bytes[start..<bytes.count]))
        }
        defer { output.removeAll(keepingCapacity: true) }
        return output
    }

    /// Feeds one line without its line break.
    public mutating func feed(line data: Data) -> [LogEntry] {
        data.withUnsafeBytes { raw in line(raw.bindMemory(to: UInt8.self)) }
        defer { output.removeAll(keepingCapacity: true) }
        return output
    }

    /// The held-back last entry, if any.
    public mutating func finish() -> [LogEntry] {
        flushPending()
        defer { output.removeAll() }
        return output
    }

    // MARK: Lines

    private mutating func line(_ raw: UnsafeBufferPointer<UInt8>) {
        if raw.count > Self.maxMessageBytes {
            // Cut on a character boundary, with "…" (3 bytes), to at most `maxMessageBytes`.
            var end = Self.maxMessageBytes - 3
            while end > 0, raw[end] & 0xC0 == 0x80 { end -= 1 }
            let cut = Array(raw[0..<end]) + Array("…".utf8)
            cut.withUnsafeBufferPointer { line($0) }
            return
        }
        var b = raw
        if let last = b.last, last == 0x0D { b = UnsafeBufferPointer(rebasing: b[0..<(b.count - 1)]) }
        lineNumber += 1
        if lineNumber == 1, b.starts(with: Self.byteOrderMark) {
            b = UnsafeBufferPointer(rebasing: b[3...])
        }
        if lineNumber == 1, b.starts(with: Self.signature) {
            isBetterConsole = true
            return
        }
        if isBetterConsole {
            if lineNumber == 2, b.starts(with: Self.hashSpace) {
                bcReader = BetterConsoleLogFormat.Reader(header: b, timeZone: timeZone)
                return
            }
            guard !b.isEmpty else { return }
            if bcReader == nil { bcReader = BetterConsoleLogFormat.Reader(timeZone: timeZone) }
            output.append(
                bcReader!.entry(b, id: takeID(), fallbackDate: modificationDate, fileName: fileName))
            return
        }
        let blank = Self.isBlank(b)
        if pending == nil {
            // Before the first entry: blank lines, dashes and `log`'s header are noise.
            guard !blank, !Self.isLogBoilerplate(b) else { return }
        } else if !blank, Self.isLogSummary(b) {
            // `log show`'s end summary (and the dashes above it) is not part of a message.
            // Other notice lookalikes inside a message ("Timestamp mismatch…") are kept.
            while let last = continuation.last, Self.isBlankOrDashes(last) { continuation.removeLast() }
            return
        }
        if !blank, b.first == UInt8(ascii: "{"), case .skip = parseJSON(b, peek: true) { return }
        if !blank, let entry = parse(b) {
            flushPending()
            pending = entry
            pendingBytes = entry.message.utf8.count
        } else if pending != nil {
            appendContinuation(Self.text(b))
        } else {
            output.append(
                LogEntry(
                    id: takeID(), date: modificationDate, level: .default, eventType: "logEvent",
                    process: fileName, message: Self.text(b)))
        }
    }

    /// Adds a line to the pending message, or, past `maxMessageLines` or `maxMessageBytes`,
    /// starts a new entry with the same date and fields holding it.
    private mutating func appendContinuation(_ text: String) {
        guard let entry = pending else { return }
        let bytes = text.utf8.count
        if continuation.count + 2 > Self.maxMessageLines || pendingBytes + 1 + bytes > Self.maxMessageBytes {
            flushPending()
            pending = entry.replacing(id: takeID(), message: text)
            pendingBytes = bytes
        } else {
            continuation.append(text)
            pendingBytes += 1 + bytes
        }
    }

    private mutating func flushPending() {
        guard let entry = pending else { return }
        pending = nil
        while let last = continuation.last, Self.isBlankText(last) { continuation.removeLast() }
        if continuation.isEmpty {
            output.append(entry)
        } else {
            output.append(entry.replacingMessage(([entry.message] + continuation).joined(separator: "\n")))
            continuation.removeAll(keepingCapacity: true)
        }
    }

    private static func text(_ b: UnsafeBufferPointer<UInt8>) -> String {
        String(decoding: b, as: UTF8.self)
    }

    private static func isBlankText(_ s: String) -> Bool {
        s.utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    private static func isBlankOrDashes(_ s: String) -> Bool {
        isBlankText(s) || (s.utf8.count >= 10 && s.utf8.allSatisfy { $0 == UInt8(ascii: "-") })
    }

    private mutating func takeID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }

    /// An entry for a line that starts a message, or nil for a continuation line.
    private mutating func parse(_ b: UnsafeBufferPointer<UInt8>) -> LogEntry? {
        if b.first == UInt8(ascii: "{") {
            switch parseJSON(b) {
            case .entry(let entry): return entry
            case .skip: return nil
            case .text: break
            }
        }
        if let fields = parse(b, style: preferred) { return makeEntry(fields) }
        for style in Style.allCases where style != preferred {
            if let fields = parse(b, style: style) {
                // Generic matches lines of every style partly; a specific style that matched
                // once stays first.
                if style != .generic { preferred = style }
                return makeEntry(fields)
            }
        }
        return nil
    }

    private enum JSONLine {
        case entry(LogEntry)
        /// `log show --style ndjson`'s closing `{"count":…,"finished":1}`.
        case skip
        /// Not a JSON object, or one with none of the known keys: text like any other line.
        case text
    }

    /// `log`'s NDJSON when the line looks like it (`eventMessage` or `messageType`) and its
    /// timestamp parses; otherwise a JSON object mapped best effort (`GenericJSON`).
    /// `peek`: only tells whether the line is to be skipped (cheap: no JSON parse unless the
    /// line names "finished").
    private mutating func parseJSON(_ b: UnsafeBufferPointer<UInt8>, peek: Bool = false) -> JSONLine {
        if peek {
            guard Self.contains(b, Self.finishedKey),
                let object = (try? JSONSerialization.jsonObject(with: Data(buffer: b))) as? [String: Any],
                Set(object.keys).isSubset(of: ["count", "finished"])
            else { return .text }
            return .skip
        }
        let data = Data(buffer: b)
        if Self.contains(b, Self.timestampKey),
            Self.contains(b, Self.eventMessageKey) || Self.contains(b, Self.messageTypeKey),
            let decoded = ndjson.decode(line: data), decoded.date.timeIntervalSince1970 != 0
        {
            let id = takeID()
            return .entry(
                decoded.process.isEmpty
                    ? decoded.replacing(id: id, process: fileName) : decoded.withID(id))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .text }
        if object["finished"] != nil, Set(object.keys).isSubset(of: ["count", "finished"]) {
            return .skip
        }
        guard let f = GenericJSON.fields(object, timeZone: timeZone) else { return .text }
        return .entry(
            LogEntry(
                id: takeID(), date: f.date ?? modificationDate, level: f.level,
                eventType: "logEvent", process: f.process ?? fileName, pid: f.pid,
                subsystem: f.subsystem, category: f.category, message: f.message ?? "",
                extra: f.extra))
    }

    private func parse(_ b: UnsafeBufferPointer<UInt8>, style: Style) -> Fields? {
        switch style {
        case .logDefault: LineStyles.logDefault(b, timeZone: timeZone)
        case .logCompact: LineStyles.logCompact(b, timeZone: timeZone)
        case .logSyslog: LineStyles.logSyslog(b, timeZone: timeZone)
        case .syslog: LineStyles.syslog(b, today: now, timeZone: timeZone)
        case .columns: LineStyles.columns(b, today: modificationDate, timeZone: timeZone)
        case .generic: LineStyles.generic(b, today: now, timeZone: timeZone)
        }
    }

    private mutating func makeEntry(_ f: Fields) -> LogEntry {
        LogEntry(
            id: takeID(), date: Date(timeIntervalSince1970: f.seconds), level: f.level,
            eventType: f.eventType, process: f.process ?? fileName, pid: f.pid, threadID: f.threadID,
            subsystem: f.subsystem, category: f.category, message: f.message,
            senderImagePath: f.library, activityID: f.activityID)
    }

    // MARK: Helpers

    private static let signature = Array(BetterConsoleLogFormat.signature.utf8)
    private static let hashSpace = Array("# ".utf8)
    private static let timestampKey = Array("\"timestamp\"".utf8)
    private static let eventMessageKey = Array("\"eventMessage\"".utf8)
    private static let messageTypeKey = Array("\"messageType\"".utf8)
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let finishedKey = Array("\"finished\"".utf8)
    private static let summaryPrefixes: [[UInt8]] = [
        "Log      - ", "Activity - ", "Signpost - ", "Trace    - ", "Loss     - ", "State    - ",
        "Timesync - ",
    ].map { Array($0.utf8) }

    private static func isBlank(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        !b.contains { $0 != 0x20 && $0 != 0x09 }
    }

    private static let timestampWord = Array("Timestamp".utf8)
    private static let boilerplatePrefixes: [[UInt8]] = [
        "Filtering the log data using ", "Skipping info and debug messages",
        "Log      - ", "Activity - ", "Signpost - ", "Trace    - ", "Loss     - ", "State    - ",
        "Timesync - ",
    ].map { Array($0.utf8) }

    /// Before the first entry: `log`'s notices (below) and lines of dashes.
    private static func isLogBoilerplate(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        if b.first == UInt8(ascii: "-") {
            return b.count >= 10 && !b.contains(where: { $0 != UInt8(ascii: "-") })
        }
        return isLogNotice(b)
    }

    /// `log`'s lines recognised by their exact start: the column header, the
    /// "Filtering…"/"Skipping…" notes and the end summary.
    private static func isLogNotice(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        // Most lines start with a digit: decided by one byte.
        guard let first = b.first, first >= 65, first <= 90 else { return false }
        // The column header: "Timestamp", then column names and no digits.
        if b.starts(with: timestampWord) { return !b.contains { $0 >= 48 && $0 <= 57 } }
        return boilerplatePrefixes.contains { b.starts(with: $0) }
    }

    /// `log show`'s end summary ("Log      - Default: …"), skipped even after an entry.
    private static func isLogSummary(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let first = b.first, first == UInt8(ascii: "L") || first == UInt8(ascii: "A")
            || first == UInt8(ascii: "S") || first == UInt8(ascii: "T")
        else { return false }
        return summaryPrefixes.contains { b.starts(with: $0) }
    }

    static func contains(_ b: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard b.count >= needle.count, let first = needle.first else { return false }
        var i = 0
        let last = b.count - needle.count
        while i <= last {
            if b[i] == first {
                var j = 1
                while j < needle.count, b[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}

/// What a line style recognised; the rest of `LogEntry` keeps its defaults.
struct Fields {
    var seconds: Double
    var level = LogLevel.default
    var eventType = "logEvent"
    var process: String?
    var pid: Int32?
    var threadID: UInt64?
    var activityID: UInt64?
    var library: String?
    var subsystem: String?
    var category: String?
    var message = ""
}

extension LogEntry {
    /// A copy with `message` replaced.
    func replacingMessage(_ message: String) -> LogEntry {
        rebuilt(id: id, process: process, message: message)
    }

    /// A copy with `id` and `message` replaced.
    func replacing(id: UInt64, message: String) -> LogEntry {
        rebuilt(id: id, process: process, message: message)
    }

    /// A copy with `id` and `process` replaced.
    func replacing(id: UInt64, process: String) -> LogEntry {
        rebuilt(id: id, process: process, message: message)
    }

    private func rebuilt(id: UInt64, process: String, message: String) -> LogEntry {
        LogEntry(
            id: id, date: date, machTimestamp: machTimestamp, level: level, eventType: eventType,
            process: process, processImagePath: processImagePath, pid: pid, threadID: threadID,
            subsystem: subsystem, category: category, message: message, formatString: formatString,
            senderImagePath: senderImagePath, activityID: activityID,
            parentActivityID: parentActivityID, traceID: traceID, userID: userID, extra: extra)
    }
}
