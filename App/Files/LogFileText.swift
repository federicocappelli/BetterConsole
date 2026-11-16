import Foundation
import UniformTypeIdentifiers

/// The words of a log file window, and the files File ▸ Open… offers.
enum LogFileText {
    /// "Loading… 45%" while the file is read.
    static func loading(progress: Double) -> String {
        "Loading… \(Int((min(max(progress, 0), 1) * 100).rounded(.down)))%"
    }

    /// The banner once the memory budget evicted the file's oldest messages.
    static func memoryLimit(kept: Int, locale: Locale = .current) -> String {
        guard kept > 0 else { return "None of this file's messages fit in the memory limit (Settings)." }
        return "Only the newest \(kept.formatted(.number.locale(locale))) messages fit in the memory limit (Settings)"
    }

    /// Logs, any plain text (`.txt`, `.log`), JSON and JSON lines (`.ndjson`, `.jsonl`).
    static let openableTypes: [UTType] = {
        var types: [UTType] = [.log, .plainText, .json]
        for ext in ["log", "ndjson", "jsonl"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()
}
