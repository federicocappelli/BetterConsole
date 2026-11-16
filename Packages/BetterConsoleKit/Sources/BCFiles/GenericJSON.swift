import Foundation
import BCModel

/// A JSON object from an application's log (not `log`'s NDJSON), mapped best effort.
enum GenericJSON {
    struct Fields {
        var date: Date?
        var level = LogLevel.default
        var message: String?
        var process: String?
        var pid: Int32?
        var subsystem: String?
        var category: String?
        /// Every key not mapped above (including a known key whose value didn't fit).
        var extra: [String: JSONValue] = [:]
    }

    static let dateKeys = ["timestamp", "time", "ts", "@timestamp"]
    static let levelKeys = ["level", "severity", "lvl"]
    static let messageKeys = ["message", "msg", "text"]
    static let processKeys = ["process", "app", "logger"]

    /// Nil unless at least a date, level, message or process was found.
    static func fields(_ object: [String: Any], timeZone: TimeZone) -> Fields? {
        var rest = object
        var f = Fields()
        var recognised = false
        for key in dateKeys where f.date == nil {
            if let value = rest[key], let date = date(value, timeZone: timeZone) {
                f.date = date
                rest[key] = nil
                recognised = true
            }
        }
        for key in levelKeys {
            if let word = rest[key] as? String, let level = LineStyles.level(forWord: word) {
                f.level = level
                rest[key] = nil
                recognised = true
                break
            }
        }
        if let (key, value) = first(of: messageKeys, in: rest) {
            f.message = value
            rest[key] = nil
            recognised = true
        }
        if let (key, value) = first(of: processKeys, in: rest) {
            f.process = value
            rest[key] = nil
            recognised = true
        }
        guard recognised else { return nil }
        if let pid = rest["pid"] {
            if let n = pid as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                let v = Int32(exactly: n.doubleValue)
            {
                f.pid = v
                rest["pid"] = nil
            } else if let s = pid as? String, let v = Int32(s) {
                f.pid = v
                rest["pid"] = nil
            }
        }
        if let s = rest["subsystem"] as? String {
            f.subsystem = s
            rest["subsystem"] = nil
        }
        if let s = rest["category"] as? String {
            f.category = s
            rest["category"] = nil
        }
        f.extra = rest.mapValues(BetterConsoleLogFormat.jsonValue)
        return f
    }

    private static func first(of keys: [String], in object: [String: Any]) -> (String, String)? {
        for key in keys {
            if let value = object[key] as? String { return (key, value) }
        }
        return nil
    }

    /// An ISO 8601 string (or `log`'s `yyyy-MM-dd HH:mm:ss.ffffff±hhmm`), or an epoch number in
    /// seconds, milliseconds, microseconds or nanoseconds, told apart by magnitude.
    static func date(_ value: Any, timeZone: TimeZone) -> Date? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let v = n.doubleValue
            let magnitude = abs(v)
            let seconds =
                magnitude < 1e11 ? v : magnitude < 1e14 ? v / 1e3 : magnitude < 1e17 ? v / 1e6 : v / 1e9
            return Date(timeIntervalSince1970: seconds)
        }
        guard var text = value as? String else { return nil }
        return text.withUTF8 { b in
            LogTimestamps.parseISO(b, at: 0, timeZone: timeZone)
                .map { Date(timeIntervalSince1970: $0.seconds) }
        }
    }
}
