import Foundation

/// Formats a log date as `HH:mm:ss.SSSSSS` (wall-clock time in `timeZone`).
///
/// `Date.FormatStyle` stops at milliseconds, and a `Date` carries about 0.12 µs of
/// floating-point error, so the microseconds are *rounded* to the nearest µs (never
/// truncated), carrying into the next second when needed. `HH:mm:ss` comes from a cached
/// `DateFormatter`; the last second's string is cached because rows arrive in time order.
///
/// Not thread-safe: use one instance per thread (the table uses it on the main actor).
final class LogTimestampFormatter {
    private let formatter: DateFormatter
    private var cachedSecond: Int64?
    private var cachedPrefix = ""

    /// `dateFormat` covers the whole seconds; `.SSSSSS` is always appended.
    init(timeZone: TimeZone = .current, dateFormat: String = "HH:mm:ss") {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        self.formatter = formatter
    }

    func string(from date: Date) -> String {
        let (seconds, micros) = Self.split(date)
        if seconds != cachedSecond {
            cachedPrefix = formatter.string(
                from: Date(timeIntervalSinceReferenceDate: TimeInterval(seconds)))
            cachedSecond = seconds
        }
        return cachedPrefix + "." + Self.sixDigits(micros)
    }

    /// Whole seconds since the reference date (floor) and the microsecond remainder
    /// (0...999_999), after rounding the whole timestamp to the nearest microsecond.
    ///
    /// Works from `timeIntervalSinceReferenceDate`, the value `Date` actually stores:
    /// converting to `timeIntervalSince1970` first would add another rounding error.
    static func split(_ date: Date) -> (seconds: Int64, micros: Int) {
        let totalMicros = Int64((date.timeIntervalSinceReferenceDate * 1_000_000).rounded())
        var seconds = totalMicros / 1_000_000
        var micros = totalMicros % 1_000_000
        if micros < 0 {  // floor division for dates before 2001
            micros += 1_000_000
            seconds -= 1
        }
        return (seconds, Int(micros))
    }

    private static func sixDigits(_ value: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }
}
