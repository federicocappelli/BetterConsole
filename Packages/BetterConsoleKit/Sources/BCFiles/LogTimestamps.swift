import Foundation

/// Fast timestamp formatting and parsing for log files, without Foundation date formatters
/// (a saved or opened file can hold millions of lines).
enum LogTimestamps {
    // MARK: Writing

    /// `2025-11-16T21:45:31.123456+01:00`: rounded to the nearest microsecond, in `timeZone`.
    static func iso8601(_ date: Date, timeZone: TimeZone) -> String {
        var writer = Writer(timeZone: timeZone)
        return writer.string(from: date)
    }

    /// Formats many dates in one zone, caching the zone offset per 15 minutes (zone
    /// transitions fall on quarter hours).
    struct Writer {
        let timeZone: TimeZone
        private var cachedBucket = Int64.min
        private var cachedOffset = 0

        init(timeZone: TimeZone) { self.timeZone = timeZone }

        mutating func string(from date: Date) -> String {
            let micros = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
            var seconds = micros / 1_000_000
            var fraction = micros % 1_000_000
            if fraction < 0 {
                fraction += 1_000_000
                seconds -= 1
            }
            let bucket = seconds >= 0 ? seconds / 900 : (seconds - 899) / 900
            if bucket != cachedBucket {
                cachedBucket = bucket
                cachedOffset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))
            }
            let offset = cachedOffset
            let local = seconds + Int64(offset)
            var days = local / 86_400
            var secondOfDay = local % 86_400
            if secondOfDay < 0 {
                secondOfDay += 86_400
                days -= 1
            }
            let (y, m, d) = civil(fromDays: Int(days))
            var out = [UInt8]()
            out.reserveCapacity(32)
            func put(_ value: Int, width: Int) {
                var digits = [UInt8](repeating: 48, count: width)
                var v = value
                for i in stride(from: width - 1, through: 0, by: -1) {
                    digits[i] = UInt8(48 + v % 10)
                    v /= 10
                }
                out.append(contentsOf: digits)
            }
            if y < 0 { out.append(UInt8(ascii: "-")) }
            put(abs(y), width: 4)
            out.append(UInt8(ascii: "-"))
            put(m, width: 2)
            out.append(UInt8(ascii: "-"))
            put(d, width: 2)
            out.append(UInt8(ascii: "T"))
            put(Int(secondOfDay / 3600), width: 2)
            out.append(UInt8(ascii: ":"))
            put(Int(secondOfDay % 3600 / 60), width: 2)
            out.append(UInt8(ascii: ":"))
            put(Int(secondOfDay % 60), width: 2)
            out.append(UInt8(ascii: "."))
            put(Int(fraction), width: 6)
            out.append(UInt8(ascii: offset < 0 ? "-" : "+"))
            put(abs(offset) / 3600, width: 2)
            out.append(UInt8(ascii: ":"))
            put(abs(offset) % 3600 / 60, width: 2)
            return String(decoding: out, as: UTF8.self)
        }
    }

    // MARK: Calendar arithmetic (Howard Hinnant's algorithms, proleptic Gregorian)

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// Seconds since 1970 for a wall-clock time in `timeZone` (`localSeconds`: the wall clock
    /// counted as if it were UTC).
    static func utcSeconds(fromLocal localSeconds: Double, timeZone: TimeZone) -> Double {
        let guess = localSeconds - Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: localSeconds)))
        return localSeconds - Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: guess)))
    }

    // MARK: Parsing

    /// A timestamp found at the start of a line.
    struct Parsed {
        /// Seconds since 1970.
        var seconds: Double
        /// Index just past the timestamp.
        var end: Int
    }

    /// `YYYY-MM-DD` then `T` or a space, `HH:MM:SS`, an optional `.` or `,` fraction and an
    /// optional zone (`Z`, `±HH:MM`, `±HHMM`, `±HH`) at `start`; a time without a zone is
    /// in `timeZone`.
    static func parseISO(_ b: UnsafeBufferPointer<UInt8>, at start: Int, timeZone: TimeZone) -> Parsed? {
        var c = ByteCursor(b, at: start)
        guard let year = c.digits(4), c.take(UInt8(ascii: "-")), let month = c.digits(2),
            c.take(UInt8(ascii: "-")), let day = c.digits(2), (1...12).contains(month),
            (1...31).contains(day)
        else { return nil }
        guard c.take(UInt8(ascii: "T")) || c.take(UInt8(ascii: " ")) else { return nil }
        guard let time = parseTime(&c) else { return nil }
        let local = Double(daysFromCivil(year: year, month: month, day: day) * 86_400) + time
        if let offset = parseZone(&c) {
            return Parsed(seconds: local - Double(offset), end: c.index)
        }
        return Parsed(seconds: utcSeconds(fromLocal: local, timeZone: timeZone), end: c.index)
    }

    /// `HH:MM:SS[.fff]` alone: on the day of `today`, in `timeZone`.
    static func parseTimeOnly(
        _ b: UnsafeBufferPointer<UInt8>, at start: Int, today: Date, timeZone: TimeZone
    ) -> Parsed? {
        var c = ByteCursor(b, at: start)
        guard let time = parseTime(&c) else { return nil }
        let local = Double(midnightLocalDays(of: today, timeZone: timeZone) * 86_400) + time
        let zone = parseZone(&c)
        let seconds = zone.map { local - Double($0) } ?? utcSeconds(fromLocal: local, timeZone: timeZone)
        return Parsed(seconds: seconds, end: c.index)
    }

    private static let months: [[UInt8]] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ].map { Array($0.utf8) }

    /// Syslog's `Nov 16 21:45:31` (or `Nov  6 …`), in the year of `today`, in `timeZone`.
    static func parseSyslog(
        _ b: UnsafeBufferPointer<UInt8>, at start: Int, today: Date, timeZone: TimeZone
    ) -> Parsed? {
        guard start + 3 <= b.count else { return nil }
        guard let month = months.firstIndex(where: { m in
            m[0] == b[start] && m[1] == b[start + 1] && m[2] == b[start + 2]
        }) else { return nil }
        var c = ByteCursor(b, at: start + 3)
        guard c.take(UInt8(ascii: " ")) else { return nil }
        _ = c.take(UInt8(ascii: " "))
        guard let day = c.digits(min: 1, max: 2), (1...31).contains(day), c.take(UInt8(ascii: " ")),
            let time = parseTime(&c)
        else { return nil }
        // No year: this year, unless that is more than a day ahead (December's logs read in
        // January), then last year.
        let year = civil(fromDays: midnightLocalDays(of: today, timeZone: timeZone)).year
        func seconds(_ year: Int) -> Double {
            let local = Double(daysFromCivil(year: year, month: month + 1, day: day) * 86_400) + time
            return utcSeconds(fromLocal: local, timeZone: timeZone)
        }
        var result = seconds(year)
        if result > today.timeIntervalSince1970 + 86_400 { result = seconds(year - 1) }
        return Parsed(seconds: result, end: c.index)
    }

    /// `HH:MM:SS` and an optional `.`/`,` fraction, as seconds into the day.
    private static func parseTime(_ c: inout ByteCursor) -> Double? {
        guard let hour = c.digits(2), c.take(UInt8(ascii: ":")), let minute = c.digits(2),
            c.take(UInt8(ascii: ":")), let second = c.digits(2), hour < 24, minute < 60, second < 61
        else { return nil }
        var fraction = 0.0
        if let p = c.peek, p == UInt8(ascii: ".") || p == UInt8(ascii: ","),
            let next = c.peek(at: 1), next >= 48, next <= 57
        {
            c.index += 1
            // Integer digits then one division: exact to the microsecond.
            var value = 0
            var scale = 1
            while let d = c.peek, d >= 48, d <= 57 {
                if scale < 1_000_000_000 {
                    value = value * 10 + Int(d - 48)
                    scale *= 10
                }
                c.index += 1
            }
            fraction = Double(value) / Double(scale)
        }
        return Double(hour * 3600 + minute * 60 + second) + fraction
    }

    /// `Z`, `±HH:MM`, `±HHMM` or `±HH`, as seconds east of UTC; nil (cursor unmoved) if none.
    private static func parseZone(_ c: inout ByteCursor) -> Int? {
        guard let p = c.peek else { return nil }
        if p == UInt8(ascii: "Z") {
            c.index += 1
            return 0
        }
        guard p == UInt8(ascii: "+") || p == UInt8(ascii: "-") else { return nil }
        var t = c
        t.index += 1
        guard let hours = t.digits(2) else { return nil }
        var minutes = 0
        if t.take(UInt8(ascii: ":")) {
            guard let m = t.digits(2) else { return nil }
            minutes = m
        } else if let m = t.digits(2) {
            minutes = m
        }
        c = t
        return (hours * 3600 + minutes * 60) * (p == UInt8(ascii: "-") ? -1 : 1)
    }

    private static func midnightLocalDays(of date: Date, timeZone: TimeZone) -> Int {
        let local = Int(date.timeIntervalSince1970.rounded(.down)) + timeZone.secondsFromGMT(for: date)
        return local >= 0 ? local / 86_400 : (local - 86_399) / 86_400
    }
}

/// Reads bytes of one line.
struct ByteCursor {
    let bytes: UnsafeBufferPointer<UInt8>
    var index: Int

    init(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int = 0) {
        self.bytes = bytes
        self.index = index
    }

    var isAtEnd: Bool { index >= bytes.count }
    var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
    func peek(at offset: Int) -> UInt8? { index + offset < bytes.count ? bytes[index + offset] : nil }

    mutating func take(_ byte: UInt8) -> Bool {
        guard peek == byte else { return false }
        index += 1
        return true
    }

    /// Exactly `count` ASCII digits.
    mutating func digits(_ count: Int) -> Int? {
        digits(min: count, max: count)
    }

    /// Between `min` and `max` ASCII digits (as many as there are, up to `max`).
    mutating func digits(min: Int, max: Int) -> Int? {
        var value = 0
        var n = 0
        while n < max, let d = peek, d >= 48, d <= 57 {
            value = value * 10 + Int(d - 48)
            index += 1
            n += 1
        }
        return n >= min ? value : nil
    }

    /// One or more spaces or tabs; false if there are none.
    @discardableResult
    mutating func skipBlanks() -> Bool {
        let from = index
        while let b = peek, b == 0x20 || b == 0x09 { index += 1 }
        return index > from
    }

    /// The bytes up to the next space or tab (or the end).
    mutating func token() -> Range<Int> {
        let from = index
        while let b = peek, b != 0x20, b != 0x09 { index += 1 }
        return from..<index
    }

    /// `0x` and hex digits.
    mutating func hex() -> UInt64? {
        guard peek == UInt8(ascii: "0"), let x = peek(at: 1), x == UInt8(ascii: "x") || x == UInt8(ascii: "X")
        else { return nil }
        var t = self
        t.index += 2
        guard let value = t.bareHex() else { return nil }
        self = t
        return value
    }

    /// Hex digits with no prefix (at least one).
    mutating func bareHex() -> UInt64? {
        var value: UInt64 = 0
        var n = 0
        while let d = peek, let v = Self.hexValue(d) {
            if n < 16 { value = value << 4 | UInt64(v) }
            n += 1
            index += 1
        }
        return n > 0 ? value : nil
    }

    static func hexValue(_ d: UInt8) -> UInt8? {
        switch d {
        case 48...57: d - 48
        case 97...102: d - 87
        case 65...70: d - 55
        default: nil
        }
    }

    func string(_ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    /// The rest of the line.
    func rest() -> String { string(index..<bytes.count) }
}
