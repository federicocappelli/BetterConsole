import Foundation
import Testing
import BCModel
@testable import BCFilter

func makeEntry(
    process: String = "proc", pid: Int32? = nil, sender: String? = nil, thread: UInt64? = nil,
    subsystem: String? = nil, category: String? = nil, level: LogLevel = .default,
    activity: UInt64? = nil, message: String = "m", date: Date = Date(timeIntervalSince1970: 1),
    eventType: String = "logEvent", processPath: String? = nil, extra: [String: JSONValue] = [:]
) -> LogEntry {
    LogEntry(
        id: 1, date: date, level: level, eventType: eventType,
        process: process, processImagePath: processPath, pid: pid, threadID: thread,
        subsystem: subsystem, category: category, message: message, senderImagePath: sender,
        activityID: activity, extra: extra)
}

private func cond(
    _ field: FilterField, _ match: MatchKind, _ value: String, key: String? = nil,
    upper: String? = nil, enabled: Bool = true
) -> FilterExpression {
    .condition(FilterCondition(
        field: field, match: match, value: value, key: key, upperValue: upper, isEnabled: enabled))
}

private func check(_ e: FilterExpression, _ entry: LogEntry) -> Bool {
    CompiledFilter(e).matches(entry)
}

/// A date on 2026-11-16 at the given local wall-clock time (the Mac's time zone).
private func localTime(_ h: Int, _ m: Int, _ s: Double = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: h, minute: m))!
    return midnight.addingTimeInterval(s)
}

@Suite struct CompiledFilterTests {
    @Test func everyFieldAndMatch() {
        let cf = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        let hit = makeEntry(
            process: "corebrightnessd", pid: 42, sender: cf, thread: 0xa6fc7,
            subsystem: "com.apple.network", category: "Plugin-Apple Internal", level: .debug,
            activity: 7, message: "Hello world")
        let miss = makeEntry(
            process: "other", pid: 43, sender: "/usr/lib/libz.dylib", thread: 1,
            subsystem: "org.x", category: "zzz", level: .error, activity: 8, message: "bye")
        let positives: [FilterExpression] = [
            cond(.process, .contains, "brigh"), cond(.process, .is, "COREBRIGHTNESSD"),
            cond(.process, .startsWith, "core"), cond(.process, .regex, "^core.*d$"),
            cond(.process, .endsWith, "NESSD"),
            cond(.pid, .is, "42"),
            cond(.library, .contains, "foundation"), cond(.library, .is, "CoreFoundation"),
            cond(.library, .startsWith, "Core"), cond(.library, .regex, "^Core.*"),
            cond(.thread, .is, "0xa6fc7"), cond(.thread, .is, "683975"),
            cond(.subsystem, .contains, "apple"), cond(.subsystem, .is, "com.apple.network"),
            cond(.subsystem, .startsWith, "com.apple"),
            cond(.subsystem, .regex, "^com\\.apple\\.(cfnet|net).*"),
            cond(.category, .contains, "Apple Internal"), cond(.category, .is, "plugin-apple internal"),
            cond(.category, .startsWith, "plugin"), cond(.category, .regex, ".*Internal$"),
            cond(.type, .is, "Debug"), cond(.activity, .is, "7"),
            cond(.message, .contains, "lo wo"), cond(.message, .is, "hello WORLD"),
            cond(.message, .startsWith, "hello"), cond(.message, .regex, ".*w.rld"),
        ]
        let negatives: [FilterExpression] = [
            cond(.process, .contains, "zz"), cond(.process, .is, "corebright"),
            cond(.process, .startsWith, "bright"), cond(.process, .regex, "^bright"),
            cond(.process, .endsWith, "core"),
            cond(.pid, .is, "43"),
            cond(.library, .contains, "zzz"), cond(.library, .is, "Core"),
            cond(.library, .startsWith, "Foundation"), cond(.library, .regex, "^Foundation"),
            cond(.thread, .is, "0xa6fc8"), cond(.thread, .is, "1"),
            cond(.subsystem, .contains, "zzz"), cond(.subsystem, .is, "com.apple"),
            cond(.subsystem, .startsWith, "network"), cond(.subsystem, .regex, "^com\\.apple\\.x"),
            cond(.category, .contains, "zzz"), cond(.category, .is, "plugin"),
            cond(.category, .startsWith, "internal"), cond(.category, .regex, "^Internal"),
            cond(.type, .is, "error"), cond(.activity, .is, "8"),
            cond(.message, .contains, "bye"), cond(.message, .is, "hello"),
            cond(.message, .startsWith, "world"), cond(.message, .regex, "^world"),
        ]
        for e in positives {
            #expect(check(e, hit), "expected match: \(e)")
            #expect(!check(e, miss), "expected no match: \(e)")
        }
        for e in negatives { #expect(!check(e, hit), "expected no match: \(e)") }
    }

    @Test func ignoresCaseIncludingAccents() {
        #expect(check(cond(.message, .contains, "éclair"), makeEntry(message: "ÉCLAIR ready")))
        #expect(!check(cond(.message, .contains, "eclair"), makeEntry(message: "ÉCLAIR ready")))
    }

    @Test func literalSpecialCharacters() {
        let e = cond(.subsystem, .is, "com.apple.(x)")
        #expect(check(e, makeEntry(subsystem: "com.apple.(x)")))
        #expect(!check(e, makeEntry(subsystem: "com.apple.x")))
        #expect(check(cond(.category, .contains, "Apple Internal"), makeEntry(category: "Plugin-Apple Internal")))
        #expect(check(cond(.message, .contains, "it's"), makeEntry(message: "it's done")))
    }

    @Test func missingValueNeverMatches() {
        let c = cond(.subsystem, .contains, "a")
        #expect(!check(c, makeEntry(subsystem: nil)))
        #expect(check(.not(c), makeEntry(subsystem: nil)))
        #expect(!check(cond(.activity, .is, "0"), makeEntry(activity: nil)))
    }

    @Test func invalidConditionsAreDropped() {
        let ok = cond(.process, .is, "x")
        let bad = cond(.process, .regex, "(")
        let f = CompiledFilter(.all([ok, bad]))
        #expect(!f.matchesEverything)
        #expect(f.matches(makeEntry(process: "x")))
        #expect(!f.matches(makeEntry(process: "y")))
        #expect(CompiledFilter(.any([bad])).matchesEverything)
        #expect(CompiledFilter(.not(bad)).matchesEverything)
        #expect(CompiledFilter(.all([bad, .any([bad])])).matchesEverything)
        #expect(CompiledFilter(.all([bad, bad])).matches(makeEntry()))
    }

    @Test func disabledConditionDropped() {
        let off = cond(.process, .is, "x", enabled: false)
        #expect(CompiledFilter(off).matchesEverything)
        let f = CompiledFilter(.all([cond(.message, .contains, "a"), off]))
        #expect(f.matches(makeEntry(process: "y", message: "a")))
    }

    @Test func nilAndEmptyMatchEverything() {
        #expect(CompiledFilter(nil).matchesEverything)
        #expect(CompiledFilter(.all([])).matchesEverything)
        #expect(CompiledFilter(nil).matches(makeEntry()))
    }

    /// Regex conditions can be slow per entry; callers check for cancellation more often.
    @Test func containsRegex() {
        let re = cond(.message, .regex, "a+"), plain = cond(.process, .is, "a")
        #expect(!CompiledFilter(nil).containsRegex)
        #expect(!CompiledFilter(plain).containsRegex)
        #expect(CompiledFilter(re).containsRegex)
        #expect(CompiledFilter(.all([plain, .any([plain, .not(re)])])).containsRegex)
        // Dropped conditions do not count.
        #expect(!CompiledFilter(cond(.message, .regex, "a+", enabled: false)).containsRegex)
        #expect(!CompiledFilter(cond(.message, .regex, "(")).containsRegex)
    }

    @Test func allAnyNot() {
        let a = cond(.process, .is, "a"), b = cond(.message, .contains, "b")
        let e = makeEntry(process: "a", message: "xx")
        #expect(!check(.all([a, b]), e))
        #expect(check(.any([a, b]), e))
        #expect(!check(.not(a), e))
    }

    @Test func valueProblems() {
        func problem(_ f: FilterField, _ m: MatchKind, _ v: String) -> String? {
            FilterCondition(field: f, match: m, value: v).valueProblem
        }
        #expect(problem(.message, .regex, "(")?.hasPrefix("Invalid regular expression") == true)
        #expect(problem(.pid, .is, "12a") != nil)
        #expect(problem(.activity, .is, "x") != nil)
        #expect(problem(.thread, .is, "0xZZ") != nil)
        #expect(problem(.type, .is, "warning") != nil)
        #expect(problem(.type, .is, "FAULT") == nil)
        #expect(problem(.thread, .is, "0xa6fc7") == nil)
        #expect(problem(.thread, .is, "12") == nil)
        #expect(problem(.pid, .is, "12") == nil)
    }

    @Test func fieldMetadata() {
        #expect(FilterField.thread.title == "Thread ID")
        #expect(FilterField.eventType.title == "Event type")
        #expect(FilterField.processPath.title == "Process path")
        #expect(FilterField.senderPath.title == "Sender path")
        #expect(FilterField.timeOfDay.title == "Time of day")
        #expect(FilterField.extra.title == "Extra data")
        let numeric: [MatchKind] = [.is, .regex, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual]
        let text: [MatchKind] = [.is, .contains, .startsWith, .endsWith, .regex]
        for f in [FilterField.pid, .thread, .activity, .type] { #expect(f.allowedMatches == numeric) }
        for f in [FilterField.process, .library, .subsystem, .category, .message, .eventType,
                  .processPath, .senderPath, .extra] {
            #expect(f.allowedMatches == text)
        }
        #expect(FilterField.timeOfDay.allowedMatches == [.between])
        #expect(MatchKind.startsWith.title == "starts with")
        #expect(MatchKind.regex.title == "matches regex (whole value)")
        #expect([MatchKind.endsWith, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual, .between]
            .map(\.title) == ["ends with", "<", "≤", ">", "≥", "between"])
        #expect(MatchKind.lessOrEqual.title(for: .type) == "at most")
        #expect(MatchKind.greaterOrEqual.title(for: .type) == "at least")
        #expect(MatchKind.lessOrEqual.title(for: .pid) == "≤")
        #expect(MatchKind.lessThan.title(for: .type) == "<")
        #expect(FilterField.allCases.map(\.predicateKey) == [
            "process", "processIdentifier", "sender", "threadIdentifier", "subsystem", "category",
            "messageType", "activityIdentifier", "eventMessage", "eventType", "processImagePath",
            "senderImagePath", "timeOfDay", "extra",
        ])
        #expect([LogLevel.default, .info, .debug, .error, .fault].map(\.logOrder) == [0, 1, 2, 16, 17])
    }

    @Test func regexMatchesWholeValue() {
        let e = makeEntry(subsystem: "com.ddg.vpn")
        #expect(!check(cond(.subsystem, .regex, "com\\.ddg"), e))
        #expect(check(cond(.subsystem, .regex, ".*com\\.ddg.*"), e))
        #expect(check(cond(.subsystem, .regex, "COM\\.DDG\\.VPN"), e))
        // MATCHES semantics: alternatives are tried until one covers the whole value.
        #expect(check(cond(.message, .regex, "a|ab"), makeEntry(message: "ab")))
        #expect(check(cond(.message, .regex, "(ab|a)b?"), makeEntry(message: "ab")))
        #expect(!check(cond(.message, .regex, "a|ab"), makeEntry(message: "abc")))
        #expect(!check(cond(.message, .regex, "b"), makeEntry(message: "ab")))
        // Anchors inside the pattern still work.
        #expect(check(cond(.subsystem, .regex, "^com\\.x$"), makeEntry(subsystem: "com.x")))
        #expect(!check(cond(.subsystem, .regex, "^com\\.x$"), makeEntry(subsystem: "com.xy")))
        // The wrapper never balances an invalid pattern.
        for bad in ["a)", "a)(?:b", "(a"] {
            let c = FilterCondition(field: .message, match: .regex, value: bad)
            #expect(c.valueProblem == "Invalid regular expression: \(bad)", "\(bad)")
            #expect(CompiledFilter(.condition(c)).matchesEverything)
        }
    }

    @Test func typeOrderIsLogs() {
        let atLeastInfo = cond(.type, .greaterOrEqual, "info")
        #expect(!check(atLeastInfo, makeEntry(level: .default)))
        for level in [LogLevel.info, .debug, .error, .fault] {
            #expect(check(atLeastInfo, makeEntry(level: level)))
        }
        #expect(check(cond(.type, .lessThan, "debug"), makeEntry(level: .info)))
        #expect(!check(cond(.type, .lessThan, "debug"), makeEntry(level: .debug)))
        #expect(check(cond(.type, .lessOrEqual, "debug"), makeEntry(level: .debug)))
        #expect(!check(cond(.type, .greaterThan, "error"), makeEntry(level: .error)))
        #expect(check(cond(.type, .greaterThan, "error"), makeEntry(level: .fault)))
    }

    @Test func numericComparisons() {
        #expect(check(cond(.pid, .greaterThan, "500"), makeEntry(pid: 501)))
        #expect(!check(cond(.pid, .greaterThan, "500"), makeEntry(pid: 500)))
        #expect(!check(cond(.pid, .greaterThan, "500"), makeEntry(pid: nil)))
        #expect(check(cond(.pid, .greaterOrEqual, "500"), makeEntry(pid: 500)))
        #expect(check(cond(.pid, .lessThan, "500"), makeEntry(pid: 499)))
        for value in ["0xa6fc7", "683975"] {
            let le = cond(.thread, .lessOrEqual, value)
            #expect(check(le, makeEntry(thread: 0xa6fc7)))
            #expect(check(le, makeEntry(thread: 0xa6fc6)))
            #expect(!check(le, makeEntry(thread: 0xa6fc8)))
        }
        #expect(check(cond(.activity, .greaterThan, "7"), makeEntry(activity: 8)))
        #expect(!check(cond(.activity, .greaterThan, "7"), makeEntry(activity: nil)))
    }

    @Test func regexOnNumbers() {
        #expect(check(cond(.thread, .regex, "0xa6.*"), makeEntry(thread: 0xa6fc7)))
        #expect(check(cond(.thread, .regex, "0xA6FC7"), makeEntry(thread: 0xa6fc7)))
        #expect(!check(cond(.thread, .regex, "683975"), makeEntry(thread: 0xa6fc7)))
        #expect(check(cond(.pid, .regex, "20[0-9]+"), makeEntry(pid: 20368)))
        #expect(!check(cond(.pid, .regex, "20[0-9]"), makeEntry(pid: 20368)))
        #expect(check(cond(.activity, .regex, "1.3"), makeEntry(activity: 123)))
        #expect(!check(cond(.activity, .regex, ".*"), makeEntry(activity: nil)))
        #expect(check(cond(.type, .regex, "de.*"), makeEntry(level: .debug)))
        #expect(check(cond(.type, .regex, "de.*"), makeEntry(level: .default)))
        #expect(!check(cond(.type, .regex, "de.*"), makeEntry(level: .error)))
        #expect(CompiledFilter(cond(.pid, .regex, "1")).containsRegex)
    }

    @Test func timeOfDayRanges() {
        let day = cond(.timeOfDay, .between, "09:00", upper: "18:00")
        #expect(check(day, makeEntry(date: localTime(9, 0))))
        #expect(!check(day, makeEntry(date: localTime(8, 59, 59.9))))
        #expect(check(day, makeEntry(date: localTime(18, 0, 59.9))))
        #expect(!check(day, makeEntry(date: localTime(18, 1))))
        #expect(check(day, makeEntry(date: localTime(12, 0))))
        let night = cond(.timeOfDay, .between, "22:00", upper: "02:00")
        #expect(check(night, makeEntry(date: localTime(23, 30))))
        #expect(check(night, makeEntry(date: localTime(1, 15))))
        #expect(check(night, makeEntry(date: localTime(2, 0, 59.9))))
        #expect(!check(night, makeEntry(date: localTime(2, 1))))
        #expect(!check(night, makeEntry(date: localTime(12, 0))))
        #expect(!check(night, makeEntry(date: localTime(21, 59, 59.9))))
        // An HH:mm:ss end includes that whole second only.
        let seconds = cond(.timeOfDay, .between, "09:00:30", upper: "09:00:45")
        #expect(!check(seconds, makeEntry(date: localTime(9, 0, 29.9))))
        #expect(check(seconds, makeEntry(date: localTime(9, 0, 45.9))))
        #expect(!check(seconds, makeEntry(date: localTime(9, 0, 46))))
        // Wrapping is decided on the end's start, so an end inside the minute before the
        // start still wraps (almost the whole day).
        let almostDay = cond(.timeOfDay, .between, "22:00", upper: "21:59")
        #expect(check(almostDay, makeEntry(date: localTime(12, 0))))
        #expect(check(almostDay, makeEntry(date: localTime(21, 59, 59.9))))
        #expect(check(almostDay, makeEntry(date: localTime(22, 0))))
        let late = cond(.timeOfDay, .between, "10:00:30", upper: "10:00")
        #expect(check(late, makeEntry(date: localTime(12, 0))))
        #expect(check(late, makeEntry(date: localTime(10, 0, 59.9))))
    }

    @Test func extraData() {
        let e = makeEntry(extra: [
            "bootUUID": .string("ABC-123"), "n": .number(42), "flag": .bool(true),
            "nested": .object(["b": .array([.number(1.5), .null]), "a": .string("x/y")]),
        ])
        #expect(check(cond(.extra, .is, "abc-123", key: "bootUUID"), e))
        #expect(check(cond(.extra, .startsWith, "ABC", key: "bootUUID"), e))
        #expect(!check(cond(.extra, .is, "x", key: "missing"), e))
        #expect(check(.not(cond(.extra, .is, "x", key: "missing")), e))
        #expect(!check(cond(.extra, .regex, ".*", key: "missing"), e))
        #expect(check(cond(.extra, .is, "42", key: "n"), e))
        #expect(check(cond(.extra, .is, "true", key: "flag"), e))
        #expect(check(cond(.extra, .is, #"{"a":"x/y","b":[1.5,null]}"#, key: "nested"), e))
        // The key is matched exactly; the value is not looked up under another key.
        #expect(!check(cond(.extra, .is, "42", key: "N"), e))
    }

    @Test func newTextFields() {
        let e = makeEntry(
            sender: "/System/Library/Frameworks/Foundation.framework/Foundation",
            eventType: "activityCreateEvent",
            processPath: "/Applications/DuckDuckGo.app/Contents/MacOS/DuckDuckGo")
        #expect(check(cond(.eventType, .is, "activityCreateEvent"), e))
        #expect(!check(cond(.eventType, .is, "logEvent"), e))
        #expect(check(cond(.processPath, .endsWith, "/DuckDuckGo"), e))
        #expect(!check(cond(.processPath, .endsWith, "/DuckDuckGo.app"), e))
        #expect(check(cond(.senderPath, .contains, "Foundation"), e))
        #expect(!check(cond(.processPath, .contains, "a"), makeEntry(processPath: nil)))
        #expect(!check(cond(.senderPath, .contains, "a"), makeEntry(sender: nil)))
    }

    @Test func linksResolveAndLoopsDrop() {
        let a = UUID(), b = UUID(), missing = UUID()
        let table: [UUID: FilterExpression] = [
            a: .all([cond(.process, .is, "A"), .link(b)]),
            b: .any([cond(.message, .contains, "b"), .link(a)]),
        ]
        let resolve: (UUID) -> FilterExpression? = { table[$0] }
        // A link compiles the linked expression in place.
        let viaB = CompiledFilter(.link(b), resolve: { _ in cond(.process, .is, "X") })
        #expect(viaB.matches(makeEntry(process: "X")))
        #expect(!viaB.matches(makeEntry(process: "Y")))
        // A missing id imposes no constraint.
        #expect(CompiledFilter(.link(missing), resolve: resolve).matchesEverything)
        #expect(CompiledFilter(.link(missing)).matchesEverything)
        let withMissing = CompiledFilter(.all([cond(.process, .is, "X"), .link(missing)]), resolve: resolve)
        #expect(withMissing.matches(makeEntry(process: "X")))
        #expect(!withMissing.matches(makeEntry(process: "Y")))
        // A -> B -> A: the inner link to A is dropped, so A = process A and (message contains b).
        let loop = CompiledFilter(.link(a), resolve: resolve)
        #expect(loop.matches(makeEntry(process: "A", message: "b")))
        #expect(!loop.matches(makeEntry(process: "A", message: "c")))
        #expect(!loop.matches(makeEntry(process: "Z", message: "b")))
        // A self-link drops too.
        let selfLink = UUID()
        #expect(CompiledFilter(.link(selfLink), resolve: { _ in .link(selfLink) }).matchesEverything)
        #expect(CompiledFilter(.link(a), resolve: { table[$0] }).containsRegex == false)
        #expect(CompiledFilter(.link(b), resolve: { _ in cond(.message, .regex, "x") }).containsRegex)
    }

    /// Review Focus 4: deep chains and diamonds evaluate as their inlined equivalents.
    @Test func deepAndDiamondLinks() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let dExpr = cond(.process, .is, "D")
        let cExpr: FilterExpression = .all([cond(.message, .contains, "c"), .link(d)])
        let bExpr: FilterExpression = .any([cond(.pid, .is, "1"), .link(c)])
        let chain: [UUID: FilterExpression] = [a: .not(.link(b)), b: bExpr, c: cExpr, d: dExpr]
        let inlinedChain: FilterExpression = .not(.any([
            cond(.pid, .is, "1"), .all([cond(.message, .contains, "c"), dExpr]),
        ]))
        // Diamond: A -> B, A -> C, B -> D, C -> D.
        let diamond: [UUID: FilterExpression] = [
            a: .all([.link(b), .link(c)]),
            b: .any([cond(.pid, .is, "1"), .link(d)]),
            c: .any([cond(.message, .contains, "c"), .link(d)]),
            d: dExpr,
        ]
        let inlinedDiamond: FilterExpression = .all([
            .any([cond(.pid, .is, "1"), dExpr]),
            .any([cond(.message, .contains, "c"), dExpr]),
        ])
        var entries: [LogEntry] = []
        for process in ["D", "E"] {
            for pid: Int32 in [1, 2] {
                for message in ["c", "x"] { entries.append(makeEntry(process: process, pid: pid, message: message)) }
            }
        }
        for (table, inlined) in [(chain, inlinedChain), (diamond, inlinedDiamond)] {
            let linked = CompiledFilter(.link(a), resolve: { table[$0] })
            let flat = CompiledFilter(inlined)
            #expect(entries.map(linked.matches) == entries.map(flat.matches))
            #expect(entries.map(flat.matches).contains(true))
            #expect(entries.map(flat.matches).contains(false))
        }
    }

    @Test func invalidNewValues() {
        func problem(_ f: FilterField, _ m: MatchKind, _ v: String, key: String? = nil,
                     upper: String? = nil) -> String? {
            FilterCondition(field: f, match: m, value: v, key: key, upperValue: upper).valueProblem
        }
        #expect(problem(.timeOfDay, .between, "9am", upper: "18:00") == "Use HH:mm or HH:mm:ss")
        #expect(problem(.timeOfDay, .between, "09:00", upper: "25:00") == "Use HH:mm or HH:mm:ss")
        #expect(problem(.timeOfDay, .between, "09:60", upper: "10:00") == "Use HH:mm or HH:mm:ss")
        #expect(problem(.timeOfDay, .between, "09:00:61", upper: "10:00") == "Use HH:mm or HH:mm:ss")
        #expect(problem(.timeOfDay, .between, "09:00", upper: nil) == "Enter an end time")
        #expect(problem(.timeOfDay, .between, "09:00", upper: "") == "Enter an end time")
        #expect(problem(.timeOfDay, .between, "09:00", upper: "9pm") == "Use HH:mm or HH:mm:ss")
        #expect(problem(.timeOfDay, .between, "09:00", upper: "18:00") == nil)
        #expect(problem(.timeOfDay, .between, "9:05:07", upper: "23:59:59") == nil)
        #expect(problem(.extra, .is, "x", key: nil) == "Enter a key")
        #expect(problem(.extra, .is, "x", key: "") == "Enter a key")
        #expect(problem(.extra, .is, "x", key: "k") == nil)
        #expect(problem(.extra, .regex, "(", key: "k") != nil)
        #expect(problem(.pid, .greaterThan, "abc") != nil)
        #expect(problem(.thread, .lessOrEqual, "0xZZ") != nil)
        #expect(problem(.activity, .lessThan, "-1") != nil)
        #expect(problem(.type, .greaterOrEqual, "warning") != nil)
        #expect(problem(.pid, .greaterThan, "5") == nil)
        #expect(problem(.thread, .lessOrEqual, "0xa6fc7") == nil)
        // Regex on numbers takes a pattern, not a number.
        #expect(problem(.pid, .regex, "20[0-9]+") == nil)
        #expect(problem(.type, .regex, "de.*") == nil)
        // Invalid values are dropped at evaluation.
        #expect(CompiledFilter(cond(.timeOfDay, .between, "x", upper: "10:00")).matchesEverything)
        #expect(CompiledFilter(cond(.extra, .is, "x", key: "")).matchesEverything)
        #expect(CompiledFilter(cond(.pid, .greaterThan, "abc")).matchesEverything)
    }

    @Test func movingToNewFields() {
        let text = FilterCondition(field: .process, match: .contains, value: "x")
        let time = text.movedTo(.timeOfDay)
        #expect(time.match == .between && time.valueProblem == nil)
        #expect(time.value == "00:00" && time.upperValue == "23:59")
        let kept = FilterCondition(field: .message, match: .is, value: "09:30").movedTo(.timeOfDay)
        #expect(kept.value == "09:30")
        // Leaving Time of day drops the end; leaving Extra data drops the key.
        let back = time.movedTo(.message)
        #expect(back.match == .is && back.upperValue == nil)
        let extra = text.movedTo(.extra)
        #expect(extra.match == .contains && extra.key == "")
        #expect(FilterCondition(field: .extra, match: .is, value: "v", key: "k").movedTo(.process).key == nil)
        // Regex and comparisons survive moves between fields that allow them.
        #expect(FilterCondition(field: .message, match: .regex, value: "4.").movedTo(.pid).match == .regex)
        #expect(FilterCondition(field: .pid, match: .greaterThan, value: "4").movedTo(.thread).match
            == .greaterThan)
        #expect(FilterCondition(field: .pid, match: .greaterThan, value: "4").movedTo(.message).match
            == .is)
        // Every moved condition uses a match its field allows.
        for from in FilterField.allCases {
            for match in from.allowedMatches {
                for to in FilterField.allCases {
                    let moved = FilterCondition(field: from, match: match, value: "1").movedTo(to)
                    #expect(to.allowedMatches.contains(moved.match), "\(from) \(match) -> \(to)")
                }
            }
        }
    }

    @Test func childOrderDoesNotChangeResults() {
        let conditions: [FilterExpression] = [
            cond(.message, .contains, "status 3"), cond(.process, .is, "Safari"),
            cond(.subsystem, .contains, "net"), cond(.type, .is, "error"),
            cond(.message, .regex, ".*after \\d+ ms"), cond(.pid, .is, "7"),
            cond(.process, .startsWith, "Saf"), cond(.category, .contains, "gen"),
        ]
        let processes = ["Safari", "Finder", "safari"], subsystems = ["com.apple.network", nil, "x"]
        let levels: [LogLevel] = [.default, .error, .debug]
        var entries: [LogEntry] = []
        for i in 0..<200 {
            let subsystem: String? = subsystems[(i / 3) % 3]
            let category: String? = i % 4 == 0 ? "general" : nil
            let message = "Request \(i) status \(i % 5) after \(i % 11) ms"
            entries.append(makeEntry(
                process: processes[i % 3], pid: Int32(i % 9), subsystem: subsystem,
                category: category, level: levels[(i / 2) % 3], message: message))
        }
        let orders: [[FilterExpression]] = [
            conditions, conditions.reversed(), conditions.shuffled(), conditions.shuffled(),
        ]
        for build in [FilterExpression.all, FilterExpression.any] {
            let results = orders.map { order in
                let f = CompiledFilter(build(order))
                return entries.map(f.matches)
            }
            #expect(results.dropFirst().allSatisfy { $0 == results[0] })
            #expect(results[0].contains(true) != results[0].contains(false))
        }
        let nested: [[Bool]] = (0..<4).map { _ in
            let anyOf = Array(conditions[0..<4].shuffled()), allOf = Array(conditions[4..<8].shuffled())
            let f = CompiledFilter(.all([.any(anyOf), .not(.all(allOf.reversed())), conditions[4]].shuffled()))
            return entries.map(f.matches)
        }
        #expect(nested.dropFirst().allSatisfy { $0 == nested[0] })
    }
}

extension CompiledFilterTests {
    /// The whole-value wrapper keeps patterns valid that end inside `\Q…` or in an extended
    /// mode `# comment`, and still matches only whole values.
    @Test func wholeValueRegexKeepsQuoteAndCommentPatterns() {
        let quote = FilterCondition(field: .message, match: .regex, value: #"\Qa.b"#)
        #expect(quote.valueProblem == nil)
        #expect(check(.condition(quote), makeEntry(message: "a.b")))
        #expect(check(.condition(quote), makeEntry(message: "A.B")))
        #expect(!check(.condition(quote), makeEntry(message: "axb")))
        #expect(!check(.condition(quote), makeEntry(message: "a.bc")))
        // Terminated quotes are left alone.
        let closed = FilterCondition(field: .message, match: .regex, value: #"\Qa.b\E.*"#)
        #expect(check(.condition(closed), makeEntry(message: "a.b and more")))
        #expect(!check(.condition(closed), makeEntry(message: "axb")))
        // A `\\` before Q is an escaped backslash, not a quote.
        let backslash = FilterCondition(field: .message, match: .regex, value: #"a\\Q"#)
        #expect(check(.condition(backslash), makeEntry(message: #"a\Q"#)))

        let comment = FilterCondition(field: .message, match: .regex, value: "(?x) a b # two letters")
        #expect(comment.valueProblem == nil)
        #expect(check(.condition(comment), makeEntry(message: "ab")))
        #expect(!check(.condition(comment), makeEntry(message: "abc")))
        #expect(!check(.condition(comment), makeEntry(message: "a b")))
        let flag = FilterCondition(field: .message, match: .regex, value: "(?ix)A # comment")
        #expect(check(.condition(flag), makeEntry(message: "a")))
        #expect(!check(.condition(flag), makeEntry(message: "ab")))
        // Still invalid: a pattern that doesn't compile on its own.
        #expect(FilterCondition(field: .message, match: .regex, value: #"a)(?:b"#).valueProblem != nil)
    }

    /// PID and Activity ID accept `0x…` hex, as `log` does.
    @Test func hexPIDAndActivityMatch() {
        let pid = FilterCondition(field: .pid, match: .is, value: "0x2A")
        #expect(pid.valueProblem == nil)
        #expect(check(.condition(pid), makeEntry(pid: 42)))
        #expect(!check(.condition(pid), makeEntry(pid: 43)))
        let activity = FilterCondition(field: .activity, match: .greaterThan, value: "0x6")
        #expect(activity.valueProblem == nil)
        #expect(check(.condition(activity), makeEntry(activity: 7)))
        #expect(!check(.condition(activity), makeEntry(activity: 6)))
        #expect(FilterCondition(field: .pid, match: .is, value: "0x").valueProblem != nil)
        #expect(FilterCondition(field: .pid, match: .is, value: "0x1FFFFFFFF").valueProblem != nil)
    }
}
