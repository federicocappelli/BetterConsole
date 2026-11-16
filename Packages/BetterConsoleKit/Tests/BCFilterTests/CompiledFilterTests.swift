import Foundation
import Testing
import BCModel
@testable import BCFilter

func makeEntry(
    process: String = "proc", pid: Int32? = nil, sender: String? = nil, thread: UInt64? = nil,
    subsystem: String? = nil, category: String? = nil, level: LogLevel = .default,
    activity: UInt64? = nil, message: String = "m"
) -> LogEntry {
    LogEntry(
        id: 1, date: Date(timeIntervalSince1970: 1), level: level, eventType: "logEvent",
        process: process, pid: pid, threadID: thread, subsystem: subsystem, category: category,
        message: message, senderImagePath: sender, activityID: activity)
}

private func cond(_ field: FilterField, _ match: MatchKind, _ value: String, enabled: Bool = true)
    -> FilterExpression
{
    .condition(FilterCondition(field: field, match: match, value: value, isEnabled: enabled))
}

private func check(_ e: FilterExpression, _ entry: LogEntry) -> Bool {
    CompiledFilter(e).matches(entry)
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
            cond(.pid, .is, "42"),
            cond(.library, .contains, "foundation"), cond(.library, .is, "CoreFoundation"),
            cond(.library, .startsWith, "Core"), cond(.library, .regex, "^Core"),
            cond(.thread, .is, "0xa6fc7"), cond(.thread, .is, "683975"),
            cond(.subsystem, .contains, "apple"), cond(.subsystem, .is, "com.apple.network"),
            cond(.subsystem, .startsWith, "com.apple"),
            cond(.subsystem, .regex, "^com\\.apple\\.(cfnet|net)"),
            cond(.category, .contains, "Apple Internal"), cond(.category, .is, "plugin-apple internal"),
            cond(.category, .startsWith, "plugin"), cond(.category, .regex, "Internal$"),
            cond(.type, .is, "Debug"), cond(.activity, .is, "7"),
            cond(.message, .contains, "lo wo"), cond(.message, .is, "hello WORLD"),
            cond(.message, .startsWith, "hello"), cond(.message, .regex, "w.rld"),
        ]
        let negatives: [FilterExpression] = [
            cond(.process, .contains, "zz"), cond(.process, .is, "corebright"),
            cond(.process, .startsWith, "bright"), cond(.process, .regex, "^bright"),
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
        #expect(FilterField.pid.allowedMatches == [.is])
        #expect(FilterField.message.allowedMatches == MatchKind.allCases)
        #expect(MatchKind.startsWith.title == "starts with")
    }

    @Test func childOrderDoesNotChangeResults() {
        let conditions: [FilterExpression] = [
            cond(.message, .contains, "status 3"), cond(.process, .is, "Safari"),
            cond(.subsystem, .contains, "net"), cond(.type, .is, "error"),
            cond(.message, .regex, "after \\d+ ms"), cond(.pid, .is, "7"),
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
