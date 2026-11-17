import Foundation
import BCModel

/// One recogniser per line style. Each returns nil unless the line starts the way its style
/// does, so a continuation line falls through every one.
enum LineStyles {
    /// `log show`/`log stream` default style:
    /// `2026-11-16 21:45:31.123456+0100 0x1a2b3 Default 0x0 1234 0 process: (Library)
    /// [sub:cat] message`.
    static func logDefault(_ b: UnsafeBufferPointer<UInt8>, timeZone: TimeZone) -> Fields? {
        guard b.count > 30, let ts = LogTimestamps.parseISO(b, at: 0, timeZone: timeZone) else { return nil }
        var c = ByteCursor(b, at: ts.end)
        guard c.skipBlanks(), let thread = c.hex(), c.skipBlanks() else { return nil }
        let typeRange = c.token()
        guard !typeRange.isEmpty, c.skipBlanks(), let activity = c.hex(), c.skipBlanks(),
            let pid = c.digits(min: 1, max: 10), c.skipBlanks(), c.digits(min: 1, max: 5) != nil
        else { return nil }
        c.skipBlanks()
        var f = Fields(seconds: ts.seconds)
        applyTypeWord(UnsafeBufferPointer(rebasing: b[typeRange]), to: &f)
        f.threadID = thread
        f.activityID = activity == 0 ? nil : activity
        f.pid = Int32(exactly: pid)
        guard let colon = processEnd(c) else {
            f.message = c.rest()
            return f
        }
        f.process = c.string(c.index..<colon)
        c.index = colon + 1
        c.skipBlanks()
        tail(&c, into: &f)
        return f
    }

    /// `log … --style compact`: `2026-11-16 21:45:31.123 E  process[1234:abcd] (Library)
    /// [sub:cat] message`.
    static func logCompact(_ b: UnsafeBufferPointer<UInt8>, timeZone: TimeZone) -> Fields? {
        guard let ts = LogTimestamps.parseISO(b, at: 0, timeZone: timeZone) else { return nil }
        var c = ByteCursor(b, at: ts.end)
        guard c.skipBlanks() else { return nil }
        let typeRange = c.token()
        var f = Fields(seconds: ts.seconds)
        switch c.string(typeRange) {
        case "Df": f.level = .default
        case "I": f.level = .info
        case "Db": f.level = .debug
        case "E", "Er": f.level = .error
        case "F", "Fa": f.level = .fault
        case "A": f.eventType = "activityCreateEvent"
        case "S", "Sp": f.eventType = "signpostEvent"
        default: return nil
        }
        guard c.skipBlanks() else { return nil }
        // process[pid:tid]; the name may hold spaces.
        var i = c.index
        while i < b.count {
            if b[i] == UInt8(ascii: "["), i > c.index {
                var t = ByteCursor(b, at: i + 1)
                if let pid = t.digits(min: 1, max: 10), t.take(UInt8(ascii: ":")), let tid = t.bareHex(),
                    t.take(UInt8(ascii: "]")), t.isAtEnd || t.peek == 0x20
                {
                    f.process = c.string(c.index..<i)
                    f.pid = Int32(exactly: pid)
                    f.threadID = tid
                    c = t
                    c.skipBlanks()
                    tail(&c, into: &f)
                    return f
                }
            }
            i += 1
        }
        return nil
    }

    /// `log … --style syslog`: `2026-11-16 21:45:31.123456+0100  localhost process[123]:
    /// (Library) [sub:cat] message`.
    static func logSyslog(_ b: UnsafeBufferPointer<UInt8>, timeZone: TimeZone) -> Fields? {
        guard let ts = LogTimestamps.parseISO(b, at: 0, timeZone: timeZone) else { return nil }
        var c = ByteCursor(b, at: ts.end)
        guard c.skipBlanks() else { return nil }
        return hostProcessAndTail(&c, seconds: ts.seconds, requirePID: true)
    }

    /// Classic syslog: `Nov 16 21:45:31 host process[123] <Notice>: message` (also
    /// `process:`), in the current year.
    static func syslog(_ b: UnsafeBufferPointer<UInt8>, today: Date, timeZone: TimeZone) -> Fields? {
        guard let ts = LogTimestamps.parseSyslog(b, at: 0, today: today, timeZone: timeZone)
        else { return nil }
        var c = ByteCursor(b, at: ts.end)
        guard c.skipBlanks() else { return nil }
        return hostProcessAndTail(&c, seconds: ts.seconds, requirePID: false)
    }

    /// `host process[pid] <Level>: …`, or `host process: …` unless `requirePID`.
    private static func hostProcessAndTail(
        _ c: inout ByteCursor, seconds: Double, requirePID: Bool
    ) -> Fields? {
        let host = c.token()
        guard !host.isEmpty, level(forWord: stripped(c.string(host))) == nil, c.skipBlanks()
        else { return nil }
        let b = c.bytes
        var f = Fields(seconds: seconds)
        // The process ends at "[pid]" or at the first ':'.
        var i = c.index
        while i < b.count, b[i] != UInt8(ascii: ":") {
            if b[i] == UInt8(ascii: "["), i > c.index {
                var t = ByteCursor(b, at: i + 1)
                if let pid = t.digits(min: 1, max: 10), t.take(UInt8(ascii: "]")) {
                    f.process = c.string(c.index..<i)
                    f.pid = Int32(exactly: pid)
                    c = t
                    break
                }
            }
            i += 1
        }
        if f.process == nil {
            guard !requirePID, i < b.count, i > c.index else { return nil }
            f.process = c.string(c.index..<i)
            c.index = i
        }
        // An optional " <Level>".
        var t = c
        t.skipBlanks()
        if t.take(UInt8(ascii: "<")) {
            let start = t.index
            while let p = t.peek, p != UInt8(ascii: ">") { t.index += 1 }
            if t.take(UInt8(ascii: ">")), let level = level(forWord: c.string(start..<(t.index - 1))) {
                f.level = level
                c = t
            }
        }
        // launchd writes `launchd[1] (service[pid]): …`: after a pid the colon is optional.
        guard c.take(UInt8(ascii: ":")) || (f.pid != nil && (c.isAtEnd || c.peek == 0x20)) else {
            return nil
        }
        c.skipBlanks()
        tail(&c, into: &f)
        return f
    }

    /// The table's columns, tab-separated, as BetterConsole's Copy writes them (and as Save Logs
    /// wrote them before the BetterConsole log format): exactly six fields — time, type name,
    /// process, subsystem, category, message. The time may be a full timestamp or a time of
    /// day alone (dated on `today`).
    static func columns(_ b: UnsafeBufferPointer<UInt8>, today: Date, timeZone: TimeZone) -> Fields? {
        var tabs: [Int] = []
        for i in b.indices where b[i] == UInt8(ascii: "\t") {
            tabs.append(i)
            if tabs.count > 5 { return nil }
        }
        guard tabs.count == 5 else { return nil }
        let time = UnsafeBufferPointer(rebasing: b[0..<tabs[0]])
        guard let ts = LogTimestamps.parseISO(time, at: 0, timeZone: timeZone)
            ?? LogTimestamps.parseTimeOnly(time, at: 0, today: today, timeZone: timeZone),
            ts.end == time.count
        else { return nil }
        let c = ByteCursor(b, at: 0)
        func field(_ n: Int) -> String {
            let start = tabs[n - 1] + 1
            let end = n < 5 ? tabs[n] : b.count
            return c.string(start..<end)
        }
        guard let level = LogLevel(rawValue: field(1).capitalized) else { return nil }
        var f = Fields(seconds: ts.seconds)
        f.level = level
        let process = field(2)
        if !process.isEmpty { f.process = process }
        let subsystem = field(3)
        if !subsystem.isEmpty { f.subsystem = subsystem }
        let category = field(4)
        if !category.isEmpty { f.category = category }
        f.message = field(5)
        return f
    }

    /// Generic: a leading timestamp (optionally in brackets), then an optional level word, an
    /// optional `process[pid]` or `process:` and an optional `[subsystem:category]`.
    static func generic(_ b: UnsafeBufferPointer<UInt8>, today: Date, timeZone: TimeZone) -> Fields? {
        let bracketed = b.first == UInt8(ascii: "[")
        let start = bracketed ? 1 : 0
        guard let ts = LogTimestamps.parseISO(b, at: start, timeZone: timeZone)
            ?? LogTimestamps.parseTimeOnly(b, at: start, today: today, timeZone: timeZone)
        else { return nil }
        var c = ByteCursor(b, at: ts.end)
        if bracketed, !c.take(UInt8(ascii: "]")) { return nil }
        guard c.isAtEnd || c.skipBlanks() else { return nil }
        var f = Fields(seconds: ts.seconds)

        // Level: "ERROR", "[error]", "<Error>", "(Error)", "error:". A bare word counts only in
        // capitals: "Error opening file" is a message.
        var t = c
        let raw = c.string(t.token())
        let word = stripped(raw)
        let marked = word != raw || (word == word.uppercased() && word != word.lowercased())
        if marked, let level = level(forWord: word) {
            f.level = level
            t.skipBlanks()
            c = t
        }

        // Process: "name[pid]", "name[pid]:" or "name:".
        t = c
        let token = t.token()
        if token.count > 1 {
            var end = token.upperBound
            if b[end - 1] == UInt8(ascii: ":") { end -= 1 }
            var named = false
            if end > token.lowerBound, b[end - 1] == UInt8(ascii: "]"),
                let open = (token.lowerBound..<end).lastIndex(where: { b[$0] == UInt8(ascii: "[") }),
                open > token.lowerBound, open + 1 < end - 1
            {
                let digits = c.string((open + 1)..<(end - 1))
                if let pid = Int32(digits) {
                    f.process = c.string(token.lowerBound..<open)
                    f.pid = pid
                    named = true
                }
            } else if end < token.upperBound, end > token.lowerBound,
                !(token.lowerBound..<end).contains(where: {
                    b[$0] == UInt8(ascii: "[") || b[$0] == UInt8(ascii: "(") || b[$0] == UInt8(ascii: ":")
                })
            {
                f.process = c.string(token.lowerBound..<end)
                named = true
            }
            if named {
                t.skipBlanks()
                c = t
            }
        }
        tail(&c, into: &f)
        return f
    }

    // MARK: Shared parts

    /// After the process: an optional `(Library)`, an optional `[subsystem:category]`, then the
    /// message.
    private static func tail(_ c: inout ByteCursor, into f: inout Fields) {
        let b = c.bytes
        if c.peek == UInt8(ascii: "(") {
            var i = c.index + 1
            while i < b.count, b[i] != UInt8(ascii: ")") { i += 1 }
            if i < b.count, i > c.index + 1, i + 1 == b.count || b[i + 1] == 0x20 {
                f.library = c.string((c.index + 1)..<i)
                c.index = i + 1
                c.skipBlanks()
            }
        }
        if c.peek == UInt8(ascii: "[") {
            var i = c.index + 1
            var colon: Int?
            while i < b.count, b[i] != UInt8(ascii: "]"), b[i] != 0x20 {
                if colon == nil, b[i] == UInt8(ascii: ":") { colon = i }
                i += 1
            }
            if i < b.count, b[i] == UInt8(ascii: "]"), let colon, colon > c.index + 1,
                i + 1 == b.count || b[i + 1] == 0x20
            {
                f.subsystem = c.string((c.index + 1)..<colon)
                f.category = colon + 1 < i ? c.string((colon + 1)..<i) : nil
                c.index = i + 1
                c.skipBlanks()
            }
        }
        f.message = c.rest()
    }

    /// Where the process name ends (the `:` of the first `": "`, or a final `:`), or nil.
    private static func processEnd(_ c: ByteCursor) -> Int? {
        let b = c.bytes
        var i = c.index
        while i < b.count {
            if b[i] == UInt8(ascii: ":"), i > c.index, i + 1 == b.count || b[i + 1] == 0x20 { return i }
            i += 1
        }
        return nil
    }

    /// `log`'s Type column: a level, or an event type for activities, signposts and the like.
    private static func applyTypeWord(_ word: UnsafeBufferPointer<UInt8>, to f: inout Fields) {
        guard let first = word.first else { return }
        // The common levels by their first byte and length, without making a string.
        switch (first, word.count) {
        case (UInt8(ascii: "D"), 7) where word[2] == UInt8(ascii: "f"): f.level = .default
        case (UInt8(ascii: "I"), 4): f.level = .info
        case (UInt8(ascii: "D"), 5): f.level = .debug
        case (UInt8(ascii: "E"), 5): f.level = .error
        case (UInt8(ascii: "F"), 5): f.level = .fault
        default:
            switch String(decoding: word, as: UTF8.self) {
            case "Activity": f.eventType = "activityCreateEvent"
            case "Signpost": f.eventType = "signpostEvent"
            case "Trace": f.eventType = "traceEvent"
            case "Loss": f.eventType = "lossEvent"
            case "State", "StateDump": f.eventType = "stateEvent"
            case "Timesync": f.eventType = "timesyncEvent"
            default: break
            }
        }
    }

    /// `word` without surrounding brackets and a trailing colon.
    private static func stripped(_ word: String) -> String {
        var w = Substring(word)
        if w.hasSuffix(":") { w = w.dropLast() }
        if (w.hasPrefix("[") && w.hasSuffix("]")) || (w.hasPrefix("<") && w.hasSuffix(">"))
            || (w.hasPrefix("(") && w.hasSuffix(")"))
        {
            w = w.dropFirst().dropLast()
        }
        return String(w)
    }

    /// A level word in any case: debug; info, notice; default; warn, warning; error, err;
    /// fault, critical, fatal (and syslog's emergency, alert).
    static func level(forWord word: String) -> LogLevel? {
        switch word.lowercased() {
        case "debug": .debug
        case "info", "notice": .info
        case "default", "warn", "warning": .default
        case "error", "err": .error
        case "fault", "critical", "crit", "fatal", "emergency", "emerg", "alert": .fault
        default: nil
        }
    }
}
