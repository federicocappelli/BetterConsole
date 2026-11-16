import BCModel

/// What Copy puts on the pasteboard for a row.
enum RowCopy {
    /// The column values joined by tabs: Type as the level's raw value, Message in full (not
    /// the cell's first line) with line breaks replaced by spaces; tabs inside values become
    /// spaces so columns do not shift.
    @MainActor
    static func line(for entry: LogEntry, columns: [LogColumn]) -> String {
        columns.map { column in
            let value = column.id == "message" ? singleLine(entry.message) : column.value(entry)
            return value.replacingOccurrences(of: "\t", with: " ")
        }.joined(separator: "\t")
    }

    /// What Copy Message puts on the pasteboard: the full message, line breaks kept.
    static func message(of entry: LogEntry) -> String { entry.message }

    /// `message` with every line break (LF, CR, CRLF) replaced by one space.
    static func singleLine(_ message: String) -> String {
        message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: " ")
    }
}
