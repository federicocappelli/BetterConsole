import Foundation
import Testing
import BCFilter
import BCModel
import BCStore
@testable import BCStreaming

extension Tag { @Tag static var performance: Self }

/// Speed targets of the filters spec (§8.3–§8.4). Skipped unless `BC_PERF=1`; meant for
/// Release: `BC_PERF=1 swift test -c release --package-path Packages/BetterConsoleKit
/// --filter FilterPerformanceTests`.
@MainActor
@Suite(.serialized, .tags(.performance), .enabled(if: ProcessInfo.processInfo.environment["BC_PERF"] == "1"))
struct FilterPerformanceTests {
    static let processes = [
        "Safari", "Finder", "kernel", "WindowServer", "Xcode", "mDNSResponder", "cfprefsd",
        "launchd", "Dock", "BetterConsole", "trustd", "networkd", "locationd", "powerd",
        "nsurlsessiond", "distnoted", "coreaudiod", "bluetoothd", "airportd", "symptomsd",
    ]
    static let subsystems: [String?] = [
        "com.apple.network", "com.apple.safari", nil, "com.apple.xpc", "com.apple.bluetooth",
        "com.apple.cfprefs", "app.betterconsole.flood", nil, "com.apple.runningboard",
    ]
    static let levels: [LogLevel] = [.default, .info, .debug, .default, .error, .info, .fault]

    /// Realistic mix: 20 processes, 9 subsystems (some nil), five levels, ~60-char messages.
    static func entry(_ i: Int) -> LogEntry {
        LogEntry(
            id: UInt64(i), date: Date(timeIntervalSince1970: Double(i) / 1000),
            level: levels[i % levels.count], eventType: "logEvent",
            process: processes[(i / 3) % processes.count],
            pid: Int32(100 + i % 400), threadID: UInt64(i % 97),
            subsystem: subsystems[(i / 7) % subsystems.count],
            category: i % 5 == 0 ? "general" : nil,
            message: "Request \(i) completed with status \(i % 7) after \(i % 913) ms for session \(i % 4001)")
    }

    /// Five bubbles, message contains "status 3" first (the default bubble), process is Safari or
    /// Finder, subsystem contains "network", type is not Debug.
    static let typical: FilterExpression = .all([
        .condition(FilterCondition(field: .message, match: .contains, value: "status 3")),
        .any([
            .condition(FilterCondition(field: .process, match: .is, value: "Safari")),
            .condition(FilterCondition(field: .process, match: .is, value: "Finder")),
        ]),
        .condition(FilterCondition(field: .subsystem, match: .contains, value: "network")),
        .not(.condition(FilterCondition(field: .type, match: .is, value: "debug"))),
    ])

    /// Same shape, but the message bubble is a regex (reported, not asserted).
    static let typicalRegex: FilterExpression = .all([
        .condition(FilterCondition(field: .message, match: .regex, value: "status [34] after")),
        .any([
            .condition(FilterCondition(field: .process, match: .is, value: "Safari")),
            .condition(FilterCondition(field: .process, match: .is, value: "Finder")),
        ]),
        .condition(FilterCondition(field: .subsystem, match: .contains, value: "network")),
        .not(.condition(FilterCondition(field: .type, match: .is, value: "debug"))),
    ])

    /// Worst case for the cheap-first ordering: every bubble must be looked at.
    static let selective: FilterExpression = .all([
        .condition(FilterCondition(field: .message, match: .contains, value: "status 3")),
        .condition(FilterCondition(field: .process, match: .is, value: "Safari")),
    ])

    @Test func liveCheckCost() {
        let n = 1_000_000
        let entries = (0..<n).map(Self.entry)
        for (name, expression) in [("typical", Self.typical), ("regex message", Self.typicalRegex),
                                   ("two bubbles", Self.selective)] {
            let filter = CompiledFilter(expression)
            var matched = 0
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                for e in entries where filter.matches(e) { matched += 1 }
            }
            let ns = Double(elapsed.components.attoseconds / 1_000_000_000) / Double(n)
                + Double(elapsed.components.seconds) * 1e9 / Double(n)
            print("PERF liveCheckCost[\(name)]: \(Int(ns)) ns/entry, \(matched) of \(n) matched")
            if name == "typical" { #expect(ns <= 3_700) }
        }
    }

    /// Runs `setFilter` on a session holding `count` entries; returns wall time to completion
    /// and the longest gap between two 1 ms main-actor heartbeats (the longest step).
    func rescan(count: Int, expression: FilterExpression) async -> (wall: Double, longest: Double, rows: Int, setFilter: Double) {
        let s = StreamSession(device: mac, transport: nil, budget: MemoryBudget())
        var i = 0
        while i < count {
            let hi = min(count, i + 50_000)
            s.store.append(contentsOf: (i..<hi).map(Self.entry))
            i = hi
        }
        func seconds(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let clock = ContinuousClock()
        var longest = 0.0
        var beating = true
        let heartbeat = Task { @MainActor in
            var last = clock.now
            while beating {
                try? await Task.sleep(for: .milliseconds(1))
                let now = clock.now
                longest = max(longest, seconds(now - last) - 0.001)
                last = now
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let start = clock.now
        s.setFilter(expression)
        let setFilterTime = seconds(clock.now - start)
        let done = await eventually(timeout: .seconds(120)) { !s.isFiltering }
        let wall = seconds(clock.now - start)
        beating = false
        await heartbeat.value
        #expect(done)
        return (wall, max(longest, setFilterTime), s.rows.count, setFilterTime)
    }

    @Test func rescan800k() async {
        let r = await rescan(count: 800_000, expression: Self.typical)
        print("PERF rescan800k[typical]: \(String(format: "%.3f", r.wall)) s wall, longest main step "
              + "\(String(format: "%.2f", r.longest * 1000)) ms (setFilter call "
              + "\(String(format: "%.2f", r.setFilter * 1000)) ms), \(r.rows) rows")
        #expect(r.wall <= 1.0)
        #expect(r.longest <= 0.004)
        let g = await rescan(count: 800_000, expression: Self.typicalRegex)
        print("PERF rescan800k[regex message]: \(String(format: "%.3f", g.wall)) s wall, longest "
              + "main step \(String(format: "%.2f", g.longest * 1000)) ms, \(g.rows) rows")
    }
}
