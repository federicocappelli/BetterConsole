import Foundation
import BCFilter

/// The filter editor's strings that depend on state (ES §6.5, §7, §8.5), kept free of UI so
/// they can be tested.
enum EditorText {
    static let errorLabel = "Text has an error — the builder shows the last valid version"
    static let fixErrorFirst = "Fix the error in the predicate first"
    static let copyAsLogPredicate = "Copy as log predicate"
    static let bannerMessage = "This filter was changed in the filter bar."
    static let discardQuestion = "Discard your changes to the filter?"
    static let tooDeep = FilterImportError.tooDeep.description

    /// Save refused because the filter would link itself (ES §9).
    static func includesItself(_ name: String) -> String { "This would make ‘\(name)’ include itself" }

    struct Count: Equatable {
        var matched: Int
        var total: Int
    }

    /// What the bottom bar shows (ES §8.5).
    enum Preview: Equatable {
        case noMessages
        case everything
        /// "Counting…", with the previous number dimmed when there is one.
        case counting(previous: Count?)
        case count(Count)
    }

    /// `stored`: the device's stored messages (0 without a session). `last`: the latest count
    /// finished for the current tree, or the previous tree's while `isCounting`.
    static func preview(stored: Int, matchesEverything: Bool, isCounting: Bool, last: Count?) -> Preview {
        if stored == 0 { return .noMessages }
        if matchesEverything { return .everything }
        if isCounting { return .counting(previous: last) }
        return last.map(Preview.count) ?? .counting(previous: nil)
    }

    static func string(_ preview: Preview, device: String) -> String {
        switch preview {
        case .noMessages: "No messages from \(device) yet"
        case .everything: "Matches every message"
        case .counting: "Counting…"
        case .count(let c): "Would match \(c.matched.formatted()) of \(c.total.formatted()) messages on \(device)"
        }
    }

    static func compatibilityNote(hasAppOnlyParts: Bool) -> String {
        hasAppOnlyParts
            ? "Works with `log stream --predicate` and in Xcode's console, except the highlighted parts, which only BetterConsole understands."
            : "Works with `log stream --predicate` and in Xcode's console."
    }

    /// After "Copy as log predicate".
    static func copied(removed: Int) -> String {
        switch removed {
        case 0: "Copied."
        case 1: "Copied. 1 part only BetterConsole understands was left out."
        default: "Copied. \(removed) parts only BetterConsole understands were left out."
        }
    }

    /// One "filter → link" line per link Import couldn't resolve.
    static func missingLinks(_ links: [(filter: String, link: String)]) -> String {
        links.map { "\($0.filter) → \($0.link)" }.joined(separator: "\n")
    }

    /// `<name>.<extension>`, with characters a file name can't hold replaced.
    static func exportFileName(name: String, fileExtension: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe).\(fileExtension)"
    }

    /// The save panel's name after the Format popup changes: the old filter extension
    /// replaced, or the new one added.
    static func renamed(_ fileName: String, toExtension ext: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let base = ["bcfilter", "json"].contains(url.pathExtension.lowercased())
            ? url.deletingPathExtension().lastPathComponent
            : fileName
        return "\(base).\(ext)"
    }

    /// Import takes `.bcfilter`, `.json`, `.txt` and files without an extension (ES §7.2).
    static func acceptsImport(_ url: URL) -> Bool {
        ["bcfilter", "json", "txt", ""].contains(url.pathExtension.lowercased())
    }
    // MARK: Filter bar

    /// The delete prompt's message when other saved filters link the one being deleted
    /// (ES §9). `dependents` is already sorted.
    static func deleteWithDependents(name: String, dependents: [String]) -> String {
        "“\(name)” is used by \(joined(dependents)). Delete it anyway? Their links will stop matching anything."
    }

    /// "A", "A and B", "A, B and C".
    static func joined(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        let rest = names.dropLast()
        return rest.isEmpty ? last : "\(rest.joined(separator: ", ")) and \(last)"
    }

    /// A link bubble's text: `FILTER <name>`, `⊘ FILTER <name>`, or "Missing filter" when the
    /// linked filter no longer exists (ES §13.6).
    static func linkBubble(name: String?, include: Bool) -> String {
        let text = name.map { "FILTER \($0)" } ?? missingFilter
        return include ? text : "⊘ \(text)"
    }

    static let missingFilter = "Missing filter"

    /// Help for a link whose filter was deleted: it imposes no constraint (ES §9).
    static let missingLinkHelp = "Missing filter: this link is ignored until you choose a filter"

    /// What the bar does after its Save (ES §9).
    enum BarSaveOutcome: Equatable {
        /// Saved: a pick waiting on the save runs.
        case saved
        /// Untitled, or its filter is gone: ask for a name, as Save As.
        case needsName
        /// Not saved, with the reason to show; the edits stay and a waiting pick is dropped.
        case refused(String)

        var runsPendingPick: Bool { self == .saved }
    }

    static func barSave(_ result: FilterWorkspace.SaveResult, filterName: String) -> BarSaveOutcome {
        switch result {
        case .saved: .saved
        case .noBaseFilter: .needsName
        case .refusedLoop: .refused(includesItself(filterName))
        case .tooDeep: .refused(tooDeep)
        }
    }

    /// The bar's Import report: the files it rejected, then the links nothing resolved
    /// (ES §7.2). Nil when there is nothing to report.
    static func importReport(
        rejected: [(fileName: String, reason: String)], missingLinks links: [(filter: String, link: String)]
    ) -> (title: String, message: String)? {
        let rejectedLines = rejected.map { "\($0.fileName): \($0.reason)" }.joined(separator: "\n")
        let missingTitle = links.count == 1 ? "A linked filter wasn't found" : "Some linked filters weren't found"
        switch (rejected.isEmpty, links.isEmpty) {
        case (true, true):
            return nil
        case (true, false):
            return (missingTitle, missingLinks(links))
        case (false, let noLinks):
            let title = rejected.count == 1
                ? "A file couldn't be imported" : "\(rejected.count) files couldn't be imported"
            let message = noLinks
                ? rejectedLines
                : "\(rejectedLines)\n\nLinked filters that weren't found:\n\(missingLinks(links))"
            return (title, message)
        }
    }
}
