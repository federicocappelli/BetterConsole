import Foundation
import Testing
import BCModel
import BCFiles

@MainActor @Suite struct RowCopyTests {
    @Test func copyLine() {
        let date = Date(timeIntervalSince1970: 1_763_049_322.584290)
        let entry = LogEntry(
            id: 1, date: date, level: .default, eventType: "logEvent",
            process: "WindowServer", subsystem: "com.apple.Multitouch", category: nil,
            message: "line one\nline two")
        let time = LogTimestampFormatter.shared.string(from: date)
        #expect(
            RowCopy.lines(for: [entry])
                == "\(time)\tDefault\tWindowServer\tcom.apple.Multitouch\t\tline one line two")
    }

    /// Copy Message copies the full message: every kind of line break and tabs kept as is
    /// (only the tab-separated row Copy flattens it).
    @Test func copyMessageKeepsLineBreaks() {
        let entry = LogEntry(
            id: 1, date: Date(timeIntervalSince1970: 0), level: .default, eventType: "logEvent",
            process: "p", message: "line one\nline two\r\nthree\tfour\n")
        #expect(RowCopy.message(of: entry) == "line one\nline two\r\nthree\tfour\n")
    }

    @Test func singleLineReplacesEveryBreak() {
        #expect(RowCopy.singleLine("a\rb") == "a b")
        #expect(RowCopy.singleLine("a\r\nb") == "a b")
        #expect(RowCopy.singleLine("a\n\nb\n") == "a  b ")
    }

    @Test func tabsInValuesBecomeSpaces() {
        let entry = LogEntry(
            id: 1, date: Date(timeIntervalSince1970: 0), level: .error, eventType: "logEvent",
            process: "a\tb", subsystem: nil, category: "c", message: "x\ty")
        let line = RowCopy.lines(for: [entry])
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        #expect(fields.count == LogColumn.defaultColumns.count)
        #expect(fields[2] == "a b")
        #expect(fields[5] == "x y")
    }

    static func entry(_ i: Int, level: LogLevel, subsystem: String?, category: String?) -> LogEntry {
        LogEntry(
            id: UInt64(i), date: Date(timeIntervalSince1970: 1_763_049_322.5 + Double(i)),
            level: level, eventType: "logEvent", process: "p\(i)",
            subsystem: subsystem, category: category, message: "message \(i)\nsecond\tline")
    }

    static let several: [LogEntry] = [
        entry(0, level: .info, subsystem: nil, category: nil),
        entry(1, level: .error, subsystem: "s", category: nil),
        entry(2, level: .fault, subsystem: nil, category: "c"),
    ]

    /// Copy with several rows selected: one line per row (as for one row), in order, joined
    /// by line breaks.
    @Test func copyLinesOfSeveralRows() {
        let rows = Self.several
        let t = rows.map { LogTimestampFormatter.shared.string(from: $0.date) }
        let expected: [String] = [
            t[0] + "\tInfo\tp0\t\t\tmessage 0 second line",
            t[1] + "\tError\tp1\ts\t\tmessage 1 second line",
            t[2] + "\tFault\tp2\t\tc\tmessage 2 second line",
        ]
        #expect(RowCopy.lines(for: rows) == expected.joined(separator: "\n"))
        #expect(
            RowCopy.lines(for: rows) == rows.map { RowCopy.lines(for: [$0]) }.joined(separator: "\n"))
    }

    /// The text is built off the main actor (large selections), with the same result.
    @Test func copyLinesOffTheMainActor() async {
        let rows = Self.several
        let text = await Task.detached { RowCopy.lines(for: rows) }.value
        #expect(text == RowCopy.lines(for: rows))
    }

    /// Copy <Column> with several rows selected: the column's value of each, joined by
    /// line breaks; Message keeps every message whole.
    @Test func copyColumnOfSeveralRows() {
        let rows = Self.several
        #expect(RowCopy.text(for: rows, column: "process") == "p0\np1\np2")
        #expect(RowCopy.text(for: rows, column: "type") == "Info\nError\nFault")
        #expect(RowCopy.text(for: rows, column: "subsystem") == "\ns\n")
        #expect(
            RowCopy.text(for: rows, column: "message")
                == "message 0\nsecond\tline\nmessage 1\nsecond\tline\nmessage 2\nsecond\tline")
        #expect(RowCopy.text(for: rows, column: nil) == RowCopy.lines(for: rows))
    }

    /// Each column's copied value comes from the same source as its cell: the cell's text,
    /// except Type (the level's name; the cell is a symbol) and Message (the full message,
    /// line breaks kept, not the cell's first line).
    @Test func valueOfEachColumnMatchesItsCell() {
        let entry = Self.several[2]
        let copied = { (id: String) in RowCopy.text(for: [entry], column: id) }
        #expect(copied("time") == LogTimestampFormatter.shared.string(from: entry.date))
        #expect(copied("type") == "Fault")
        #expect(copied("process") == "p2")
        #expect(copied("subsystem") == "")
        #expect(copied("category") == "c")
        #expect(copied("message") == "message 2\nsecond\tline")
        for column in LogColumn.defaultColumns where column.id != "message" {
            #expect(copied(column.id) == column.value(entry), "\(column.id)")
        }
        #expect(LogColumn.defaultColumns.first { $0.id == "message" }!.value(entry) == "message 2")
    }

    // MARK: Save Logs

    /// "<device> <yyyy-MM-dd HH-mm>.log" in the given time zone; characters a file name
    /// can't hold are replaced.
    @Test func logFileName() {
        let date = Date(timeIntervalSince1970: 1_763_049_322)  // 2025-11-13 15:55:22 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(
            RowCopy.logFileName(deviceName: "Someone’s MacBook Pro", date: date, timeZone: utc)
                == "Someone’s MacBook Pro 2025-11-13 15-55.log")
        #expect(
            RowCopy.logFileName(
                deviceName: "a/b:c", date: date, timeZone: TimeZone(identifier: "Europe/Rome")!)
                == "a-b-c 2025-11-13 16-55.log")
    }

    /// The file is the BetterConsole log format: its header, then each chunk's lines (every
    /// field, escaped), a final line break, UTF-8. Copy keeps the 6-column text.
    @Test func logFileData() {
        let rows = Self.several
        let data = RowCopy.logFileData([
            RowCopy.saveLines(for: Array(rows[0..<2])), RowCopy.saveLines(for: [rows[2]]),
        ])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("# BetterConsole log 1\n# date\ttype\tprocess\t"))
        #expect(text == BetterConsoleLogFormat.header + "\n" + BetterConsoleLogFormat.lines(for: rows) + "\n")
        #expect(RowCopy.logFileData([]) == Data((BetterConsoleLogFormat.header + "\n").utf8))
        #expect(RowCopy.saveLines(for: rows) != RowCopy.lines(for: rows))
    }

    /// What Save Logs writes, opened again, gives back every field.
    @Test func savedFileReopens() throws {
        let entry = LogEntry(
            id: 9, date: Date(timeIntervalSince1970: 1_763_049_322.584290), level: .fault,
            eventType: "logEvent", process: "café", processImagePath: "/usr/bin/café", pid: 12,
            threadID: 0xabc, subsystem: "com.x", category: "c\tat", message: "naïve\nline\\x",
            senderImagePath: "/usr/lib/libx.dylib", activityID: 5, extra: ["k": .bool(true)])
        let data = RowCopy.logFileData([RowCopy.saveLines(for: [entry])])
        let read = LogFileParser.parse(data, fileName: "saved.log")
        try #require(read.count == 1)
        #expect(read[0].message == entry.message)
        #expect(read[0].category == entry.category)
        #expect(read[0].process == "café")
        #expect(read[0].pid == 12)
        #expect(read[0].threadID == 0xabc)
        #expect(read[0].senderImagePath == entry.senderImagePath)
        #expect(read[0].activityID == 5)
        #expect(read[0].extra == ["k": .bool(true)])
        #expect(read[0].level == .fault)
        #expect(abs(read[0].date.timeIntervalSince(entry.date)) < 0.000_001)
    }

    @Test func menuTitles() {
        #expect(
            LogColumn.defaultColumns.map(RowCopy.menuTitle(for:)) == [
                "Copy Time", "Copy Type", "Copy Process", "Copy Subsystem", "Copy Category",
                "Copy Message",
            ])
    }

    /// Chunks of a large copy are joined by line breaks, as if copied at once.
    @Test func chunksJoinLikeOneCopy() {
        let rows = Self.several
        #expect(
            RowCopy.joined([RowCopy.lines(for: Array(rows[0..<2])), RowCopy.lines(for: [rows[2]])])
                == RowCopy.lines(for: rows))
        #expect(RowCopy.joined([]) == "")
    }
}
