import Foundation
import Testing
import BCModel
@testable import BCFiles

@Suite struct LogFileParserTests {
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-16 12:00:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_794_830_400)
    static let modified = Date(timeIntervalSince1970: 1_794_800_000)

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func parse(_ data: Data, name: String = "app.log", timeZone: TimeZone = utc) -> [LogEntry] {
        LogFileParser.parse(data, fileName: name, modificationDate: modified, now: now, timeZone: timeZone)
    }

    static func parse(_ text: String, name: String = "app.log", timeZone: TimeZone = utc) -> [LogEntry] {
        parse(Data(text.utf8), name: name, timeZone: timeZone)
    }

    /// Seconds since 1970 for a UTC wall-clock time, microseconds exact.
    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, micros: Int = 0) -> Date {
        let days = LogTimestamps.daysFromCivil(year: y, month: mo, day: d)
        return Date(timeIntervalSince1970: Double(days * 86_400 + h * 3600 + mi * 60 + s) + Double(micros) / 1e6)
    }

    static func micros(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1e6).rounded()) }

    // MARK: log show default style

    @Test func logDefaultStyle() throws {
        let e = Self.parse(try Self.fixture("log-default.txt"))
        try #require(e.count == 8)
        #expect(Self.micros(e[0].date) == Self.micros(Self.date(2026, 11, 16, 22, 42, 59, micros: 699_132)))
        #expect(e[0].level == .info)
        #expect(e[0].threadID == 0x34d15)
        #expect(e[0].pid == 717)
        #expect(e[0].process == "exchangesyncd")
        #expect(e[0].senderImagePath == "libusrtcp.dylib")
        #expect(e[0].subsystem == "com.apple.network")
        #expect(e[0].category == nil)
        #expect(e[0].message == "tcp_run_timerlist mode 1 drift 72 / offset 10")
        #expect(e[0].eventType == "logEvent")
        #expect(e[0].activityID == nil)

        #expect(e[1].category == "Client,LAContext")
        #expect(e[1].message == "LAContext[4:14:206] deallocated")
        #expect(e[2].senderImagePath == nil)
        #expect(e[2].subsystem == "com.apple.icloud.searchpartyd")
        #expect(e[3].process == "kernel")
        #expect(e[3].pid == 0)
        #expect(e[3].message == "arm_cpu_init(): cpu 4 online")
        // +0100 offset.
        #expect(Self.micros(e[4].date) == Self.micros(Self.date(2026, 11, 16, 21, 43, 3, micros: 549_167)))
        #expect(e[4].level == .error)
        #expect(e[4].senderImagePath == "Sandbox")
        #expect(e[4].message == "Sandbox: logd_helper(422) deny(1) file-read-data /private/var/tmp/x")
        #expect(e[5].eventType == "activityCreateEvent")
        #expect(e[5].activityID == 0x130e33)
        #expect(e[5].level == .default)
        // Process names with spaces, a message starting with a bracket, continuation lines.
        #expect(e[6].process == "Google Chrome Helper")
        #expect(e[6].level == .fault)
        #expect(e[6].subsystem == "com.apple.xpc")
        #expect(e[6].message == "[0x7ab7365cc0] first line\nsecond line of the fault\n\tthird line, indented")
        #expect(e[7].level == .debug)
        #expect(e[7].subsystem == nil)
        #expect(e[7].message == "[0x1] no subsystem here")
    }

    // MARK: compact

    @Test func logCompactStyle() throws {
        let e = Self.parse(try Self.fixture("log-compact.txt"))
        try #require(e.count == 6)
        #expect(Self.micros(e[0].date) == Self.micros(Self.date(2026, 11, 16, 22, 43, 1, micros: 287_000)))
        #expect(e[0].level == .default)
        #expect(e[0].process == "bluetoothd")
        #expect(e[0].pid == 416)
        #expect(e[0].threadID == 0x334e7)
        #expect(e[0].subsystem == "com.apple.bluetooth")
        #expect(e[0].category == "Server.LE.Scan")
        #expect(e[0].message == "Scanning started successfully")
        #expect(e[1].level == .info)
        #expect(e[1].senderImagePath == "CoreBluetooth")
        #expect(e[2].level == .debug)
        #expect(e[2].process == "Google Chrome Helper (Renderer)")
        #expect(e[2].message == "debug line")
        #expect(e[3].level == .error)
        #expect(e[3].message == "tcp connected: [<IPv4-redacted>:50487] interface: en0\nso_gencnt: 79611 t_state: ESTABLISHED")
        #expect(e[4].level == .fault)
        #expect(e[5].eventType == "activityCreateEvent")
    }

    /// A compact-style time has no zone: it is in the parser's time zone.
    @Test func compactTimesAreLocal() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let e = Self.parse("2026-11-16 09:00:00.000 Df p[1:2] m", timeZone: tokyo)
        #expect(e.first.map { Self.micros($0.date) } == Self.micros(Self.date(2026, 11, 16, 0, 0, 0)))
    }

    // MARK: syslog styles

    @Test func logSyslogStyle() throws {
        let e = Self.parse(try Self.fixture("log-syslog.txt"))
        try #require(e.count == 3)
        #expect(e[0].process == "cloudd")
        #expect(e[0].pid == 744)
        #expect(e[0].senderImagePath == "libxpc.dylib")
        #expect(e[0].subsystem == "com.apple.xpc")
        #expect(e[0].category == "connection")
        #expect(e[0].message == "[0x7bef6d7e80] invalidated")
        #expect(e[2].process == "kernel")
        #expect(e[2].subsystem == nil)
        #expect(e[2].message == "[ 4479.719972]: arm_cpu_init(): cpu 5 online")
    }

    @Test func classicSyslog() throws {
        let e = Self.parse(try Self.fixture("syslog.txt"))
        try #require(e.count == 4)
        #expect(Self.micros(e[0].date) == Self.micros(Self.date(2026, 11, 16, 21, 45, 31)))
        #expect(e[0].process == "com.apple.xpc.launchd")
        #expect(e[0].pid == 1)
        #expect(e[0].message == "(com.apple.mdworker.shared[12345]): Service exited")
        #expect(Self.micros(e[1].date) == Self.micros(Self.date(2026, 11, 6, 9, 5, 7)))
        #expect(e[1].level == .info)
        #expect(e[1].process == "syslogd")
        #expect(e[1].message == "ASL Sender Statistics")
        #expect(e[2].level == .error)
        #expect(e[3].process == "backupd")
        #expect(e[3].pid == nil)
        #expect(e[3].message == "Starting automatic backup\n    continued line")
    }

    // MARK: NDJSON

    @Test func ndjson() throws {
        let e = Self.parse(try Self.fixture("log.ndjson"), name: "kernel.ndjson")
        try #require(e.count == 2)
        #expect(e[0].level == .fault)
        #expect(e[0].process == "exampled")
        #expect(e[0].processImagePath == "/usr/libexec/exampled")
        #expect(e[0].pid == 21345)
        #expect(e[0].subsystem == "com.example.sub")
        #expect(e[0].message == "hello 1")
        #expect(e[0].formatString == "hello %d")
        #expect(e[0].traceID == 42)
        #expect(e[0].senderImagePath == "/usr/lib/libexample.dylib")
        #expect(Self.micros(e[0].date) == Self.micros(Self.date(2026, 11, 13, 15, 55, 22, micros: 273_495)))
        // No process path: the file's name.
        #expect(e[1].process == "kernel.ndjson")
        // The closing {"count":…,"finished":1} is skipped, not appended.
        #expect(e[1].message == "no process path")
        #expect(e[1].level == .info)
        #expect(e.map(\.id) == [1, 2])
    }

    // MARK: Generic

    @Test func genericLines() throws {
        let e = Self.parse(try Self.fixture("generic.txt"), name: "server.log")
        try #require(e.count == 7, "\(e.map(\.message))")
        // A leading line with no timestamp: its own message, dated with the file's date.
        #expect(e[0].message == "Starting app (no timestamp yet)")
        #expect(e[0].date == Self.modified)
        #expect(e[0].process == "server.log")
        #expect(e[0].level == .default)

        #expect(Self.micros(e[1].date) == Self.micros(Self.date(2026, 11, 16, 21, 45, 31, micros: 123_000)))
        #expect(e[1].level == .info)
        #expect(e[1].process == "server")
        #expect(e[1].pid == 42)
        #expect(e[1].message == "listening on :8080")

        #expect(Self.micros(e[2].date) == Self.micros(Self.date(2026, 11, 16, 21, 45, 32, micros: 500_000)))
        #expect(e[2].level == .error)
        #expect(e[2].process == "worker")
        #expect(e[2].message == "job failed\nTraceback (most recent call last):\n  File \"x.py\", line 1")

        #expect(e[3].level == .default)  // WARNING
        #expect(e[3].process == "server.log")
        #expect(e[3].message == "something odd [com.example.app:net] happened")

        #expect(Self.micros(e[4].date) == Self.micros(Self.date(2026, 11, 16, 19, 45, 34)))
        #expect(e[4].level == .fault)
        #expect(e[4].message == "boom")

        // A time alone: today (in the parser's zone).
        #expect(Self.micros(e[5].date) == Self.micros(Self.date(2026, 11, 16, 21, 45, 35, micros: 250_000)))
        #expect(e[5].level == .debug)
        #expect(e[5].message == "plain message")

        #expect(e[6].subsystem == "com.example.app")
        #expect(e[6].category == "ui")
        #expect(e[6].message == "subsystem only\ngarbage line ~~~ !!!")
        #expect(e.map(\.eventType).allSatisfy { $0 == "logEvent" })
        #expect(e.map(\.id) == Array(1...7))
    }

    @Test(arguments: [
        ("debug", LogLevel.debug), ("INFO", .info), ("Notice", .info), ("default", .default),
        ("warn", .default), ("WARNING", .default), ("error", .error), ("ERR", .error),
        ("fault", .fault), ("critical", .fault), ("FATAL", .fault),
    ])
    func genericLevelWords(word: String, level: LogLevel) throws {
        // A bare word counts only in capitals ("Error opening file" is a message).
        for form in [word.uppercased(), "[\(word)]", "<\(word)>", "\(word):"] {
            let e = Self.parse("2026-11-16T10:00:00Z \(form) message")
            try #require(e.count == 1)
            #expect(e[0].level == level, "\(form)")
            #expect(e[0].message == "message", "\(form)")
        }
    }

    @Test func timestampForms() {
        let expected = Self.micros(Self.date(2026, 11, 16, 10, 0, 0))
        for line in [
            "2026-11-16T10:00:00Z m", "2026-11-16 10:00:00 m", "2026-11-16T11:00:00+01:00 m",
            "2026-11-16T11:00:00+0100 m", "2026-11-16T11:00:00+01 m", "2026-11-16T10:00:00.000000Z m",
            "[2026-11-16 10:00:00] m", "2026-11-16T10:00:00,000Z m",
        ] {
            let e = Self.parse(line)
            #expect(e.count == 1, "\(line)")
            #expect(e.first.map { Self.micros($0.date) } == expected, "\(line)")
            #expect(e.first?.message == "m", "\(line)")
        }
    }

    // MARK: Robustness

    @Test func crlfEmptyLinesAndGarbage() {
        let text = "\r\n\r\ngarbage \u{1}\u{2}\r\n2026-11-16T10:00:00Z a\r\n\r\nmore\r\n   \r\n2026-11-16T10:00:01Z b\r\n"
        let e = Self.parse(text)
        // Blank lines inside a message stay; trailing ones (even "   ") go.
        #expect(e.map(\.message) == ["garbage \u{1}\u{2}", "a\n\nmore", "b"])
    }

    @Test func invalidUTF8IsReplacedNotFatal() {
        var data = Data("2026-11-16T10:00:00Z bad ".utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(contentsOf: Array("\n2026-11-16T10:00:01Z ok".utf8))
        let e = Self.parse(data)
        #expect(e.count == 2)
        #expect(e.first?.message == "bad \u{FFFD}\u{FFFD}")
        #expect(e.last?.message == "ok")
    }

    @Test func emptyFile() {
        #expect(Self.parse(Data()).isEmpty)
        #expect(Self.parse("\n\n  \n").isEmpty)
    }

    /// Fed in arbitrary chunks of whole lines, the result is the same as parsing at once.
    @Test func feedingInChunksMatchesParsingAtOnce() throws {
        let data = try Self.fixture("generic.txt") + Self.fixture("log-default.txt")
        let whole = Self.parse(data)
        var parser = LogFileParser(fileName: "app.log", modificationDate: Self.modified, now: Self.now, timeZone: Self.utc)
        var chunked: [LogEntry] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            chunked += parser.feed(line: Data(line))
        }
        chunked += parser.finish()
        #expect(chunked.map(\.message) == whole.map(\.message))
        #expect(chunked.map(\.id) == whole.map(\.id))
    }

    /// 200k lines (default style, some continuations) in under 2 s, even in a debug build.
    @Test func parsesTwoHundredThousandLinesQuickly() throws {
        var text = ""
        text.reserveCapacity(200_000 * 170)
        for i in 0..<200_000 {
            if i % 10 == 9 {
                text += "    continuation line \(i)\n"
            } else {
                text += "2026-11-16 22:42:59.\(String(format: "%06d", i % 1_000_000))+0000 0x34bdf    Default     0x0                  554    0    searchpartyd: (LocalAuthentication) [com.apple.LocalAuthentication:Client] message number \(i)\n"
            }
        }
        let data = Data(text.utf8)
        let clock = ContinuousClock()
        let started = clock.now
        let e = Self.parse(data)
        let elapsed = clock.now - started
        #expect(e.count == 180_000)
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }
}
