import Foundation
import BCFiles
import BCModel

/// What Copy, Copy <Column> and Save Logs write for rows. Copied values come from the column's
/// own `LogColumn.text` (the cell's source), so the copied text cannot drift from the cell;
/// Save Logs writes every field in the BetterConsole log format, so the file reopens exactly.
/// Safe off the main actor: each call uses a timestamp formatter of its own.
enum RowCopy {
    /// The text Copy (`column` nil: whole rows) or Copy <Column> (`column`: a column id) puts
    /// on the pasteboard for `entries`: one row or value per entry, joined by line breaks.
    ///
    /// A whole row is the default columns' values joined by tabs: Type as the level's name,
    /// Message in full (not the cell's first line) with line breaks replaced by spaces; tabs
    /// inside values become spaces so columns do not shift.
    nonisolated static func text(for entries: [LogEntry], column: String?) -> String {
        let formatter = LogTimestampFormatter()
        let columns = LogColumn.defaultColumns
        if let column {
            guard let copied = columns.first(where: { $0.id == column }) else { return "" }
            return entries.map { value(of: copied, for: $0, formatter: formatter) }
                .joined(separator: "\n")
        }
        return entries.map { entry in
            columns.map { column in
                let value =
                    column.id == "message"
                    ? singleLine(entry.message) : self.value(of: column, for: entry, formatter: formatter)
                return value.replacingOccurrences(of: "\t", with: " ")
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// Copy with several rows: whole rows, one per line.
    nonisolated static func lines(for entries: [LogEntry]) -> String {
        text(for: entries, column: nil)
    }

    /// The pieces of a copy made in chunks, joined as if copied at once.
    nonisolated static func joined(_ pieces: [String]) -> String {
        pieces.joined(separator: "\n")
    }

    /// What Copy <Column> copies for one row: the cell's text, except Message (the full
    /// message, line breaks kept). Type's text is the level's name (its cell is a symbol).
    private nonisolated static func value(
        of column: LogColumn, for entry: LogEntry, formatter: LogTimestampFormatter
    ) -> String {
        column.id == "message" ? message(of: entry) : column.text(entry, formatter)
    }

    /// The context menu item for copying `column`: "Copy Process".
    static func menuTitle(for column: LogColumn) -> String { "Copy \(column.title)" }

    /// What Copy Message puts on the pasteboard: the full message, line breaks kept.
    nonisolated static func message(of entry: LogEntry) -> String { entry.message }

    /// `message` with every line break (LF, CR, CRLF) replaced by one space.
    nonisolated static func singleLine(_ message: String) -> String {
        message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: " ")
    }

    // MARK: Save Logs

    /// Save Logs' suggested name: "<device> <yyyy-MM-dd HH-mm>.log" in `timeZone`, with
    /// characters a file name can't hold replaced.
    static func logFileName(deviceName: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return EditorText.exportFileName(
            name: "\(deviceName) \(formatter.string(from: date))", fileExtension: "log")
    }

    /// A chunk of Save Logs' file: one BetterConsole-format line per entry (every field), in
    /// the current time zone.
    nonisolated static func saveLines(for entries: [LogEntry]) -> String {
        BetterConsoleLogFormat.lines(for: entries)
    }

    /// Save Logs' file from the chunks of `saveLines(for:)`: the format's header, then each
    /// chunk followed by a line break, UTF-8.
    nonisolated static func logFileData(_ pieces: [String]) -> Data {
        BetterConsoleLogFormat.fileData(pieces)
    }
}
