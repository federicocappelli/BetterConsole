import Foundation

/// Decodes one NDJSON line from `log stream --style ndjson` into a `LogEntry`.
public struct LogEntryDecoder {
    private var nextID: UInt64 = 1

    public init() {}

    /// Returns nil for lines that are not a JSON object (headers, truncated or binary lines).
    /// Ids are assigned only to lines that decode, starting at 1.
    public mutating func decode(line: Data) -> LogEntry? {
        guard let parsed = try? JSONSerialization.jsonObject(with: line),
              var fields = parsed as? [String: Any]
        else { return nil }

        let imagePath = Self.string(fields.removeValue(forKey: "processImagePath"))
        let entry = LogEntry(
            id: nextID,
            date: Self.date(fields.removeValue(forKey: "timestamp")),
            machTimestamp: Self.uint64(fields.removeValue(forKey: "machTimestamp")),
            level: LogLevel(messageType: fields.removeValue(forKey: "messageType") as? String),
            eventType: (fields.removeValue(forKey: "eventType") as? String) ?? "",
            process: imagePath.map(Self.lastPathComponent) ?? "",
            processImagePath: imagePath,
            pid: Self.uint64(fields.removeValue(forKey: "processID")).flatMap { Int32(exactly: $0) },
            threadID: Self.uint64(fields.removeValue(forKey: "threadID")),
            subsystem: Self.string(fields.removeValue(forKey: "subsystem")),
            category: Self.string(fields.removeValue(forKey: "category")),
            message: (fields.removeValue(forKey: "eventMessage") as? String) ?? "",
            formatString: Self.string(fields.removeValue(forKey: "formatString")),
            senderImagePath: Self.string(fields.removeValue(forKey: "senderImagePath")),
            activityID: Self.uint64(fields.removeValue(forKey: "activityIdentifier")),
            parentActivityID: Self.uint64(fields.removeValue(forKey: "parentActivityIdentifier")),
            traceID: Self.uint64(fields.removeValue(forKey: "traceID")),
            userID: Self.uint64(fields.removeValue(forKey: "userID")).flatMap { UInt32(exactly: $0) },
            extra: fields.mapValues(Self.jsonValue)
        )
        nextID += 1
        return entry
    }

    // MARK: - Field helpers

    /// The last non-empty `/`-separated component ("" if there is none). Works on the
    /// `NSString` that `JSONSerialization` produced: `String.split` on a bridged string walks
    /// it grapheme by grapheme and took ~30 % of decoding time.
    static func lastPathComponent(_ path: String) -> String {
        let ns = path as NSString
        var end = ns.length
        while end > 0, ns.character(at: end - 1) == 0x2F { end -= 1 }
        guard end > 0 else { return "" }
        let slash = ns.range(of: "/", options: .backwards, range: NSRange(location: 0, length: end))
        let start = slash.location == NSNotFound ? 0 : slash.location + 1
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    /// Empty strings become nil.
    private static func string(_ any: Any?) -> String? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func uint64(_ any: Any?) -> UInt64? {
        guard let n = any as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        guard d >= 0, d == d.rounded() else { return nil }
        return n.uint64Value
    }

    private static func jsonValue(_ any: Any) -> JSONValue {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber: return isBool(n) ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: return .array(a.map(jsonValue))
        case let o as [String: Any]: return .object(o.mapValues(jsonValue))
        default: return .null
        }
    }

    // MARK: - Timestamp

    /// Parses `yyyy-MM-dd HH:mm:ss.ffffff±hhmm` without Foundation date formatters.
    /// Unparseable input yields the Unix epoch.
    private static func date(_ any: Any?) -> Date {
        guard let text = any as? String, let seconds = unixSeconds(text) else {
            return Date(timeIntervalSince1970: 0)
        }
        // Date stores a Double, which has ~0.12 microsecond error at current epochs.
        // Display code must round to the nearest microsecond, never truncate.
        return Date(timeIntervalSince1970: seconds)
    }

    private static func unixSeconds(_ text: String) -> Double? {
        var it = text.utf8.makeIterator()
        func digits(_ count: Int) -> Int? {
            var v = 0
            for _ in 0..<count {
                guard let c = it.next(), c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        func expect(_ ch: Character) -> Bool { it.next() == ch.asciiValue }

        guard let year = digits(4), expect("-"), let month = digits(2), expect("-"), let day = digits(2),
              expect(" "), let hour = digits(2), expect(":"), let minute = digits(2), expect(":"),
              let second = digits(2), (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var fraction = 0.0
        var scale = 0.1
        var next = it.next()
        if next == UInt8(ascii: ".") {
            next = it.next()
            while let c = next, c >= 48, c <= 57 {
                fraction += Double(c - 48) * scale
                scale /= 10
                next = it.next()
            }
        }
        var offset = 0
        if let sign = next, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
            guard let oh = digits(2), let om = digits(2) else { return nil }
            offset = (oh * 3600 + om * 60) * (sign == UInt8(ascii: "-") ? -1 : 1)
        }

        let wholeSeconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3600 + minute * 60 + second - offset
        return Double(wholeSeconds) + fraction
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
