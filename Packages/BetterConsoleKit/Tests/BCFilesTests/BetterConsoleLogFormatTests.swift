import Foundation
import Testing
import BCModel
@testable import BCFiles

@Suite struct BetterConsoleLogFormatTests {
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private static func full(id: UInt64 = 1, date: Date) -> LogEntry {
        LogEntry(
            id: id, date: date, machTimestamp: 999, level: .error, eventType: "logEvent",
            process: "Safari", processImagePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            pid: 1234, threadID: 0x1a2b3, subsystem: "com.apple.WebKit", category: "Network",
            message: "hello\tworld\nline two\\end", formatString: "hello %s",
            senderImagePath: "/System/Library/Frameworks/WebKit.framework/WebKit",
            activityID: 77, parentActivityID: 3, traceID: 42, userID: 501,
            extra: ["b": .number(2), "a": .string("x\ty")])
    }

    @Test func headerLines() {
        #expect(BetterConsoleLogFormat.signature == "# BetterConsole log 1")
        #expect(
            BetterConsoleLogFormat.header == """
                # BetterConsole log 1
                # date\ttype\tprocess\tpid\tthread\tsubsystem\tcategory\tlibrary\tactivity\t\
                parentActivity\teventType\tprocessPath\tsenderPath\tmessage\textra\tformatString\t\
                traceID\tuserID
                """)
    }

    @Test func lineHasEveryFieldInColumnOrder() {
        // 2025-11-16 21:45:31.123456 in Berlin (UTC+1).
        let date = Date(timeIntervalSince1970: 1_763_325_931.123456)
        let line = BetterConsoleLogFormat.line(for: Self.full(date: date), timeZone: Self.berlin)
        let fields = line.components(separatedBy: "\t")
        #expect(fields.count == BetterConsoleLogFormat.columns.count)
        #expect(
            fields == [
                "2025-11-16T21:45:31.123456+01:00", "Error", "Safari", "1234", "0x1a2b3",
                "com.apple.WebKit", "Network", "WebKit", "77", "3", "logEvent",
                "/Applications/Safari.app/Contents/MacOS/Safari",
                "/System/Library/Frameworks/WebKit.framework/WebKit",
                "hello\\tworld\\nline two\\\\end", #"{"a":"x\\ty","b":2}"#, "hello %s", "42", "501",
            ])
    }

    @Test func missingValuesAreEmpty() {
        let entry = LogEntry(
            id: 1, date: Date(timeIntervalSince1970: 0), level: .default, eventType: "",
            process: "", message: "")
        let line = BetterConsoleLogFormat.line(for: entry, timeZone: TimeZone(identifier: "UTC")!)
        #expect(line == "1970-01-01T00:00:00.000000+00:00\tDefault" + String(repeating: "\t", count: 16))
    }

    @Test func dateRoundsToTheNearestMicrosecondAndUsesTheZoneOffset() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let ny = TimeZone(identifier: "America/New_York")!
        let date = Date(timeIntervalSince1970: 1_763_325_931.9999996)
        #expect(LogTimestamps.iso8601(date, timeZone: tokyo) == "2025-11-17T05:45:32.000000+09:00")
        #expect(LogTimestamps.iso8601(date, timeZone: ny) == "2025-11-16T15:45:32.000000-05:00")
        // Summer time.
        let july = Date(timeIntervalSince1970: 1_751_371_200)  // 2025-07-01T12:00:00Z
        #expect(LogTimestamps.iso8601(july, timeZone: Self.berlin) == "2025-07-01T14:00:00.000000+02:00")
        // Before 1970.
        let old = Date(timeIntervalSince1970: -1.5)
        #expect(LogTimestamps.iso8601(old, timeZone: TimeZone(identifier: "UTC")!) == "1969-12-31T23:59:58.500000+00:00")
    }

    @Test func escapeAndUnescape() {
        let raw = "a\\b\tc\nd\re\\t"
        let escaped = BetterConsoleLogFormat.escape(raw)
        #expect(escaped == #"a\\b\tc\nd\re\\t"#)
        #expect(BetterConsoleLogFormat.unescape(escaped) == raw)
        // A lone or unknown escape is kept as is.
        #expect(BetterConsoleLogFormat.unescape(#"x\qy\"#) == #"x\qy\"#)
    }

    @Test func roundTripsAFullEntry() throws {
        let date = Date(timeIntervalSince1970: 1_763_325_931.123456)
        let entry = Self.full(id: 9, date: date)
        let text = BetterConsoleLogFormat.header + "\n" + BetterConsoleLogFormat.line(for: entry) + "\n"
        let read = LogFileParser.parse(Data(text.utf8), fileName: "x.log")
        try #require(read.count == 1)
        expectSameFields(read[0], entry)
    }

    /// Random entries with tabs, line breaks, backslashes and Unicode in every string field
    /// come back exactly (dates to the microsecond; `id` and `machTimestamp` are not kept).
    @Test func roundTripsRandomEntries() throws {
        var rng = SeededGenerator(seed: 0xBE77E2)
        let entries = (0..<500).map { RandomEntries.entry(id: UInt64($0 + 1), using: &rng) }
        var text = BetterConsoleLogFormat.header + "\n"
        text += entries.map { BetterConsoleLogFormat.line(for: $0) }.joined(separator: "\n")
        let read = LogFileParser.parse(Data(text.utf8), fileName: "random.log")
        try #require(read.count == entries.count)
        for (a, b) in zip(read, entries) { expectSameFields(a, b) }
    }

    @Test func readsColumnsInAnyOrderAndIgnoresUnknownOnes() throws {
        let text = """
            # BetterConsole log 1
            # message\tsomethingNew\ttype\tdate\tprocess
            hi\tzzz\tFault\t2025-11-16T21:45:31.500000+01:00\tkernel
            """
        let read = LogFileParser.parse(Data(text.utf8), fileName: "f.log")
        try #require(read.count == 1)
        #expect(read[0].message == "hi")
        #expect(read[0].level == .fault)
        #expect(read[0].process == "kernel")
        #expect(read[0].date == Date(timeIntervalSince1970: 1_763_325_931.5))
    }

    /// A library with no sender path (a parsed `(Library)`) is kept as the sender path, so the
    /// Library filter still matches it.
    @Test func libraryWithoutSenderPathBecomesTheSenderPath() throws {
        let text = """
            # BetterConsole log 1
            # date\tprocess\tlibrary\tsenderPath\tmessage
            2025-11-16T21:45:31.500000+01:00\tp\tlibfoo.dylib\t\tm
            """
        let read = LogFileParser.parse(Data(text.utf8), fileName: "f.log")
        #expect(read.first?.senderImagePath == "libfoo.dylib")
    }

    @Test func crlfLineEndingsAndEmptyLines() throws {
        let entry = Self.full(date: Date(timeIntervalSince1970: 1_763_325_931.25))
        let text = BetterConsoleLogFormat.header.replacingOccurrences(of: "\n", with: "\r\n")
            + "\r\n\r\n" + BetterConsoleLogFormat.line(for: entry) + "\r\n\r\n"
        let read = LogFileParser.parse(Data(text.utf8), fileName: "x.log")
        try #require(read.count == 1)
        expectSameFields(read[0], entry)
    }

    @Test func fileDataIsHeaderPlusOneLinePerEntry() {
        let a = Self.full(date: Date(timeIntervalSince1970: 1))
        let b = Self.full(date: Date(timeIntervalSince1970: 2))
        let pieces = [BetterConsoleLogFormat.lines(for: [a]), BetterConsoleLogFormat.lines(for: [b])]
        let data = BetterConsoleLogFormat.fileData(pieces)
        let expected = BetterConsoleLogFormat.header + "\n" + BetterConsoleLogFormat.line(for: a) + "\n"
            + BetterConsoleLogFormat.line(for: b) + "\n"
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }
}

/// Every field except `id` and `machTimestamp`, dates to the microsecond.
func expectSameFields(_ a: LogEntry, _ b: LogEntry, sourceLocation: SourceLocation = #_sourceLocation) {
    func micros(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1_000_000).rounded()) }
    #expect(micros(a.date) == micros(b.date), sourceLocation: sourceLocation)
    #expect(a.level == b.level, sourceLocation: sourceLocation)
    #expect(a.eventType == b.eventType, sourceLocation: sourceLocation)
    #expect(a.process == b.process, sourceLocation: sourceLocation)
    #expect(a.processImagePath == b.processImagePath, sourceLocation: sourceLocation)
    #expect(a.pid == b.pid, sourceLocation: sourceLocation)
    #expect(a.threadID == b.threadID, sourceLocation: sourceLocation)
    #expect(a.subsystem == b.subsystem, sourceLocation: sourceLocation)
    #expect(a.category == b.category, sourceLocation: sourceLocation)
    #expect(a.message == b.message, sourceLocation: sourceLocation)
    #expect(a.formatString == b.formatString, sourceLocation: sourceLocation)
    #expect(a.senderImagePath == b.senderImagePath, sourceLocation: sourceLocation)
    #expect(a.activityID == b.activityID, sourceLocation: sourceLocation)
    #expect(a.parentActivityID == b.parentActivityID, sourceLocation: sourceLocation)
    #expect(a.traceID == b.traceID, sourceLocation: sourceLocation)
    #expect(a.userID == b.userID, sourceLocation: sourceLocation)
    #expect(a.extra == b.extra, sourceLocation: sourceLocation)
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum RandomEntries {
    private static let pieces = [
        "a", "Zz", " ", "\t", "\n", "\r", "\r\n", "\\", "\\t", "\\n", "é", "日本", "🙂", "#", "{", "\"",
        ":", "[x:y]", "0x1f",
    ]

    static func string<G: RandomNumberGenerator>(using rng: inout G, allowEmpty: Bool = true) -> String {
        let n = Int.random(in: (allowEmpty ? 0 : 1)...8, using: &rng)
        return (0..<n).map { _ in pieces.randomElement(using: &rng)! }.joined()
    }

    static func optional<G: RandomNumberGenerator>(using rng: inout G) -> String? {
        // The format writes nil as "", so a present value is never empty.
        Bool.random(using: &rng) ? nil : string(using: &rng, allowEmpty: false)
    }

    static func number<T: FixedWidthInteger, G: RandomNumberGenerator>(_: T.Type, using rng: inout G) -> T? {
        Bool.random(using: &rng) ? nil : T.random(in: 0...T.max, using: &rng)
    }

    static func json<G: RandomNumberGenerator>(depth: Int = 0, using rng: inout G) -> JSONValue {
        switch Int.random(in: 0...(depth > 1 ? 3 : 5), using: &rng) {
        case 0: .string(string(using: &rng))
        case 1: .number(Double(Int.random(in: -1_000_000...1_000_000, using: &rng)) / 8)
        case 2: .bool(Bool.random(using: &rng))
        case 3: .null
        case 4: .array((0..<Int.random(in: 0...3, using: &rng)).map { _ in json(depth: depth + 1, using: &rng) })
        default:
            .object(
                Dictionary(
                    (0..<Int.random(in: 0...3, using: &rng)).map { _ in
                        (string(using: &rng), json(depth: depth + 1, using: &rng))
                    }, uniquingKeysWith: { a, _ in a }))
        }
    }

    static func entry<G: RandomNumberGenerator>(id: UInt64, using rng: inout G) -> LogEntry {
        let micros = Int64.random(in: -2_000_000_000_000_000...4_000_000_000_000_000, using: &rng)
        let levels: [LogLevel] = [.default, .info, .debug, .error, .fault]
        var extra: [String: JSONValue] = [:]
        for _ in 0..<Int.random(in: 0...3, using: &rng) { extra[string(using: &rng)] = json(using: &rng) }
        return LogEntry(
            id: id, date: Date(timeIntervalSince1970: Double(micros) / 1_000_000),
            machTimestamp: number(UInt64.self, using: &rng),
            level: levels.randomElement(using: &rng)!,
            eventType: string(using: &rng), process: string(using: &rng),
            processImagePath: optional(using: &rng), pid: number(Int32.self, using: &rng),
            threadID: number(UInt64.self, using: &rng), subsystem: optional(using: &rng),
            category: optional(using: &rng), message: string(using: &rng),
            formatString: optional(using: &rng), senderImagePath: optional(using: &rng),
            activityID: number(UInt64.self, using: &rng),
            parentActivityID: number(UInt64.self, using: &rng),
            traceID: number(UInt64.self, using: &rng), userID: number(UInt32.self, using: &rng),
            extra: extra)
    }
}
