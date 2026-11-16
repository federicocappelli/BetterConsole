import Foundation
import Testing
import BCModel
@testable import BCFiles

/// Review fixes: generic JSON lines, blank and dash lines inside messages, level words in the
/// generic style, BOM, message caps, bare CR line breaks, syslog year rollover, file identity.
@Suite struct LogFileParserReviewTests {
    typealias T = LogFileParserTests

    // MARK: JSON

    /// A `timestamp` key alone no longer sends a line to `log`'s decoder (1970, no message).
    @Test func genericJSONWithTimestampKey() throws {
        let e = T.parse(#"{"timestamp":"2026-11-16T10:00:00.5Z","msg":"hello","level":"warning"}"#)
        try #require(e.count == 1)
        #expect(e[0].message == "hello")
        #expect(T.micros(e[0].date) == T.micros(T.date(2026, 11, 16, 10, 0, 0, micros: 500_000)))
        #expect(e[0].level == .default)
        #expect(e[0].process == "app.log")
    }

    @Test func genericJSONMapsKnownKeysAndKeepsTheRestInExtra() throws {
        let line = #"{"time":"2026-11-16T10:00:00Z","level":"error","msg":"boom","app":"svc","pid":7,"subsystem":"s","category":"c","user":"u","n":3}"#
        let e = T.parse(line)
        try #require(e.count == 1)
        #expect(e[0].level == .error)
        #expect(e[0].message == "boom")
        #expect(e[0].process == "svc")
        #expect(e[0].pid == 7)
        #expect(e[0].subsystem == "s")
        #expect(e[0].category == "c")
        #expect(e[0].extra == ["user": .string("u"), "n": .number(3)])
        #expect(e[0].eventType == "logEvent")
    }

    @Test(arguments: [
        #"{"ts":1794830400,"message":"m"}"#,  // seconds
        #"{"ts":1794830400000,"message":"m"}"#,  // milliseconds
        #"{"ts":1794830400000000,"message":"m"}"#,  // microseconds
        #"{"@timestamp":"2026-11-16T12:00:00Z","text":"m"}"#,
        #"{"timestamp":"2026-11-16 12:00:00.000000+0000","message":"m"}"#,
    ])
    func genericJSONDates(line: String) throws {
        let e = T.parse(line)
        try #require(e.count == 1)
        #expect(T.micros(e[0].date) == T.micros(T.now))
        #expect(e[0].message == "m")
    }

    @Test func genericJSONKeyAliases() throws {
        let e = T.parse(#"{"severity":"FATAL","logger":"db","text":"t"}"# + "\n" + #"{"lvl":"debug","process":"p","message":"x"}"#)
        try #require(e.count == 2)
        #expect(e[0].level == .fault)
        #expect(e[0].process == "db")
        #expect(e[0].message == "t")
        #expect(e[0].date == T.modified)  // no date: the file's
        #expect(e[1].level == .debug)
        #expect(e[1].process == "p")
    }

    /// JSON with none of the known keys, or not JSON at all, is text like any other line.
    @Test func unknownJSONIsText() {
        let e = T.parse(#"{"foo":1}"# + "\n2026-11-16T10:00:00Z a\n" + #"{"bar":2}"# + "\n{not json")
        #expect(e.map(\.message) == [#"{"foo":1}"#, "a\n" + #"{"bar":2}"# + "\n{not json"])
    }

    /// `log`'s ndjson still goes through its decoder; one whose timestamp doesn't parse is
    /// mapped as generic JSON instead of dated 1970.
    @Test func logLikeJSONNeedsAParsedTimestamp() throws {
        let good = #"{"timestamp":"2026-11-16 12:00:00.000000+0000","messageType":"Error","eventMessage":"x","processImagePath":"/bin/p","formatString":"%s"}"#
        let bad = #"{"timestamp":"nope","messageType":"Error","eventMessage":"y","message":"z"}"#
        let e = T.parse(good + "\n" + bad)
        try #require(e.count == 2)
        #expect(e[0].message == "x")
        #expect(e[0].formatString == "%s")
        #expect(e[0].process == "p")
        #expect(e[1].message == "z")
        #expect(e[1].date == T.modified)
        #expect(e[1].level == .default)
        #expect(e[1].extra["eventMessage"] == .string("y"))
    }

    // MARK: Blank, dash and boilerplate lines

    @Test func blankAndDashLinesStayInTheMessage() {
        let e = T.parse("2026-11-16T10:00:00Z a\n\n---------------\nmore\n\n\n2026-11-16T10:00:01Z b\n\n")
        #expect(e.map(\.message) == ["a\n\n---------------\nmore", "b"])
    }

    @Test func logBoilerplateIsSkipped() {
        let text = """
            ----------------------------------------
            Timestamp                       Thread     Type        Activity             PID    TTL
            2026-11-16 10:00:00.000000+0000 0x1    Default     0x0                  1      0    p: a
            --------------------------------------------------------------------------------
            Log      - Default:          1, Info:                0, Debug:             0
            Activity - Create:           0, Transition:          0, Actions:           0
            """
        #expect(T.parse(text).map(\.message) == ["a"])
    }

    /// Inside a message, lines that only look like `log`'s header or notes are kept.
    @Test func noticeLookalikesInsideAMessageAreKept() {
        let e = T.parse("2026-11-16T10:00:00Z a\nTimestamp mismatch in header\nFiltering the log data using x\n")
        #expect(e.map(\.message) == ["a\nTimestamp mismatch in header\nFiltering the log data using x"])
    }

    @Test func booleanPIDIsNotAPID() throws {
        let e = T.parse(#"{"msg":"m","pid":true}"#)
        try #require(e.count == 1)
        #expect(e[0].pid == nil)
        #expect(e[0].extra["pid"] == .bool(true))
    }

    // MARK: Level words in the generic style

    @Test func capitalisedWordStaysInTheMessage() {
        let e = T.parse("2026-11-16T10:00:00Z Error opening file")
        #expect(e.first?.level == .default)
        #expect(e.first?.message == "Error opening file")
        let caps = T.parse("2026-11-16T10:00:00Z ERROR opening file")
        #expect(caps.first?.level == .error)
        #expect(caps.first?.message == "opening file")
        for form in ["[error]", "<error>", "error:", "(Error)"] {
            let x = T.parse("2026-11-16T10:00:00Z \(form) opening file")
            #expect(x.first?.level == .error, "\(form)")
            #expect(x.first?.message == "opening file", "\(form)")
        }
    }

    // MARK: BOM

    @Test func byteOrderMarkIsIgnored() throws {
        let entry = LogEntry(
            id: 1, date: T.now, level: .info, eventType: "logEvent", process: "p", message: "m")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(BetterConsoleLogFormat.fileData([BetterConsoleLogFormat.lines(for: [entry])]))
        let e = T.parse(data)
        try #require(e.count == 1)
        expectSameFields(e[0], entry)
        var generic = Data([0xEF, 0xBB, 0xBF])
        generic.append(Data("2026-11-16T10:00:00Z hi".utf8))
        #expect(T.parse(generic).first?.message == "hi")
    }

    // MARK: Caps

    /// Past 10,000 lines, a message goes on in a new entry with the same date and fields.
    @Test func messageLineCap() throws {
        var text = "2026-11-16T10:00:00Z ERROR p[3]: head\n"
        for i in 1..<15_000 { text += "line \(i)\n" }
        let e = T.parse(text)
        try #require(e.count == 2)
        #expect(e[0].message.split(separator: "\n", omittingEmptySubsequences: false).count == 10_000)
        #expect(e[1].message.split(separator: "\n", omittingEmptySubsequences: false).count == 5_000)
        #expect(e[1].message.hasPrefix("line 10000\n"))
        #expect(e[1].date == e[0].date)
        #expect(e[1].process == "p")
        #expect(e[1].pid == 3)
        #expect(e[1].level == .error)
        #expect(e[1].id == e[0].id + 1)
    }

    /// Past 1 MiB, likewise; a single line over 1 MiB is cut there and ends with "…".
    @Test func messageByteCap() throws {
        let chunk = String(repeating: "x", count: 600 * 1024)
        let e = T.parse("2026-11-16T10:00:00Z head\n\(chunk)\n\(chunk)\n")
        try #require(e.count == 2)
        #expect(e[0].message.utf8.count <= LogFileParser.maxMessageBytes)
        #expect(e[1].message == chunk)
        let huge = String(repeating: "é", count: 700 * 1024)  // 1.4 MiB of 2-byte characters
        let h = T.parse("2026-11-16T10:00:00Z \(huge)")
        try #require(h.count == 1)
        #expect(h[0].message.hasSuffix("…"))
        #expect(h[0].message.utf8.count <= LogFileParser.maxMessageBytes + 3)
        #expect(!h[0].message.contains("\u{FFFD}"))
    }

    // MARK: Bare CR

    @Test func bareCarriageReturnsBreakLinesWhenThereIsNoLineFeed() {
        let e = T.parse("2026-11-16T10:00:00Z a\r2026-11-16T10:00:01Z b\rcont\r")
        #expect(e.map(\.message) == ["a", "b\ncont"])
        // With line feeds, a lone CR inside a line is kept.
        let lf = T.parse("2026-11-16T10:00:00Z a\rb\n")
        #expect(lf.map(\.message) == ["a\rb"])
    }

    // MARK: Syslog year

    @Test func syslogDatesAfterTomorrowAreLastYear() {
        let e = T.parse("Dec 20 10:00:00 host p: old\nNov 17 10:00:00 host p: tomorrow")
        #expect(e.map { T.micros($0.date) } == [
            T.micros(T.date(2025, 12, 20, 10, 0, 0)), T.micros(T.date(2026, 11, 17, 10, 0, 0)),
        ])
    }
}

@Suite struct FileIdentityTests {
    @Test func symlinkedPathsAreOneFile() throws {
        #expect(
            FileLogTransport.device(for: URL(fileURLWithPath: "/var/tmp/x.log")).id
                == FileLogTransport.device(for: URL(fileURLWithPath: "/private/var/tmp/x.log")).id)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("real.log")
        try Data("x".utf8).write(to: real)
        let link = dir.appendingPathComponent("link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(FileLogTransport.device(for: link).id == FileLogTransport.device(for: real).id)
        #expect(FileLogTransport.device(for: link).name == "link.log")
    }

    /// A file with only CR line breaks is read in batches, not held whole until the end.
    @Test func carriageReturnOnlyFileStreams() async throws {
        var text = ""
        for i in 0..<3_000 { text += "2026-11-16T10:00:00Z message \(i)\r" }
        let url = try FileLogTransportTests.tempFile(text)
        let transport = FileLogTransport(url: url, chunkSize: 4_096)
        var batches = 0
        var count = 0
        for try await batch in transport.stream(from: transport.device) {
            batches += 1
            count += batch.count
        }
        #expect(count == 3_000)
        #expect(batches > 1)
    }
}
