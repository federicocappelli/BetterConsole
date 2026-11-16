import Foundation
import Testing
import BCModel

@MainActor @Suite struct RowCopyTests {
    @Test func copyLine() {
        let date = Date(timeIntervalSince1970: 1_763_049_322.584290)
        let entry = LogEntry(
            id: 1, date: date, level: .default, eventType: "logEvent",
            process: "WindowServer", subsystem: "com.apple.Multitouch", category: nil,
            message: "line one\nline two")
        let time = LogTimestampFormatter.shared.string(from: date)
        #expect(
            RowCopy.line(for: entry, columns: LogColumn.defaultColumns)
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
        let line = RowCopy.line(for: entry, columns: LogColumn.defaultColumns)
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        #expect(fields.count == LogColumn.defaultColumns.count)
        #expect(fields[2] == "a b")
        #expect(fields[5] == "x y")
    }
}
