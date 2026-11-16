import Foundation
import Testing
import BCFilter

@Suite struct EditorTextTests {
    @Test func previewStates() {
        #expect(EditorText.preview(stored: 0, matchesEverything: false, isCounting: true, last: nil) == .noMessages)
        #expect(EditorText.preview(stored: 0, matchesEverything: true, isCounting: false, last: nil) == .noMessages)
        #expect(EditorText.preview(stored: 10, matchesEverything: true, isCounting: true, last: nil) == .everything)
        #expect(
            EditorText.preview(stored: 10, matchesEverything: false, isCounting: true, last: .init(matched: 3, total: 9))
                == .counting(previous: .init(matched: 3, total: 9)))
        #expect(
            EditorText.preview(stored: 10, matchesEverything: false, isCounting: false, last: .init(matched: 4, total: 10))
                == .count(.init(matched: 4, total: 10)))
        // Not counted yet and not counting (the first count hasn't started): Counting….
        #expect(EditorText.preview(stored: 10, matchesEverything: false, isCounting: false, last: nil) == .counting(previous: nil))
    }

    @Test func previewStrings() {
        #expect(EditorText.string(.noMessages, device: "This Mac") == "No messages from This Mac yet")
        #expect(EditorText.string(.everything, device: "This Mac") == "Matches every message")
        #expect(EditorText.string(.counting(previous: nil), device: "This Mac") == "Counting…")
        let n = 1204.formatted(), m = 45348.formatted()
        #expect(
            EditorText.string(.count(.init(matched: 1204, total: 45348)), device: "This Mac")
                == "Would match \(n) of \(m) messages on This Mac")
    }

    @Test func compatibilityNote() {
        #expect(EditorText.compatibilityNote(hasAppOnlyParts: false)
            == "Works with `log stream --predicate` and in Xcode's console.")
        #expect(EditorText.compatibilityNote(hasAppOnlyParts: true)
            == "Works with `log stream --predicate` and in Xcode's console, except the highlighted parts, which only BetterConsole understands.")
    }

    @Test func copiedConfirmation() {
        #expect(EditorText.copied(removed: 0) == "Copied.")
        #expect(EditorText.copied(removed: 1) == "Copied. 1 part only BetterConsole understands was left out.")
        #expect(EditorText.copied(removed: 3) == "Copied. 3 parts only BetterConsole understands were left out.")
    }

    @Test func missingLinks() {
        #expect(
            EditorText.missingLinks([(filter: "DDG", link: "Noise"), (filter: "Noise", link: "Gone")])
                == "DDG → Noise\nNoise → Gone")
    }

    @Test func exportFileName() {
        #expect(EditorText.exportFileName(name: "DDG Errors", fileExtension: "bcfilter") == "DDG Errors.bcfilter")
        #expect(EditorText.exportFileName(name: "a/b:c", fileExtension: "json") == "a-b-c.json")
        // Switching the format swaps the extension the user sees, and keeps the rest.
        #expect(EditorText.renamed("My Filter.json", toExtension: "bcfilter") == "My Filter.bcfilter")
        #expect(EditorText.renamed("My Filter", toExtension: "json") == "My Filter.json")
        #expect(EditorText.renamed("v1.2 notes.bcfilter", toExtension: "json") == "v1.2 notes.json")
    }

    @Test func importAcceptsFilterFilesTextAndNoExtension() {
        for name in ["a.bcfilter", "a.json", "a.JSON", "a.txt", "README"] {
            #expect(EditorText.acceptsImport(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["a.png", "a.swift"] {
            #expect(!EditorText.acceptsImport(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }
    // MARK: Filter bar (Task 10)

    @Test func deleteMessageNamesDependents() {
        #expect(
            EditorText.deleteWithDependents(name: "Noise Exclusions", dependents: ["DDG Errors", "VPN Debug"])
                == "“Noise Exclusions” is used by DDG Errors and VPN Debug. Delete it anyway? Their links will stop matching anything.")
        #expect(
            EditorText.deleteWithDependents(name: "Noise", dependents: ["DDG Errors"])
                == "“Noise” is used by DDG Errors. Delete it anyway? Their links will stop matching anything.")
        #expect(
            EditorText.deleteWithDependents(name: "Noise", dependents: ["A", "B", "C"])
                == "“Noise” is used by A, B and C. Delete it anyway? Their links will stop matching anything.")
    }

    @Test func linkBubbleText() {
        #expect(EditorText.linkBubble(name: "Noise", include: true) == "FILTER Noise")
        #expect(EditorText.linkBubble(name: "Noise", include: false) == "⊘ FILTER Noise")
        #expect(EditorText.linkBubble(name: nil, include: true) == "Missing filter")
        #expect(EditorText.linkBubble(name: nil, include: false) == "⊘ Missing filter")
    }

    @Test func importReport() {
        #expect(EditorText.importReport(rejected: [], missingLinks: []) == nil)
        let rejected = EditorText.importReport(rejected: [(fileName: "a.json", reason: "Bad")], missingLinks: [])
        #expect(rejected?.title == "A file couldn't be imported")
        #expect(rejected?.message == "a.json: Bad")
        let two = EditorText.importReport(
            rejected: [(fileName: "a.json", reason: "Bad"), (fileName: "b.txt", reason: "Worse")], missingLinks: [])
        #expect(two?.title == "2 files couldn't be imported")
        #expect(two?.message == "a.json: Bad\nb.txt: Worse")
        let missing = EditorText.importReport(rejected: [], missingLinks: [(filter: "DDG", link: "Noise")])
        #expect(missing?.title == "A linked filter wasn't found")
        #expect(missing?.message == "DDG → Noise")
        let both = EditorText.importReport(
            rejected: [(fileName: "a.json", reason: "Bad")],
            missingLinks: [(filter: "DDG", link: "Noise"), (filter: "VPN", link: "Gone")])
        #expect(both?.title == "A file couldn't be imported")
        #expect(both?.message == "a.json: Bad\n\nLinked filters that weren't found:\nDDG → Noise\nVPN → Gone")
        let manyMissing = EditorText.importReport(
            rejected: [], missingLinks: [(filter: "DDG", link: "Noise"), (filter: "VPN", link: "Gone")])
        #expect(manyMissing?.title == "Some linked filters weren't found")
    }

    /// The bar's Save (ES §9): a refused save shows why and keeps the edits, so the pick that
    /// was waiting on it (from the unsaved-edits prompt) is not run.
    @Test func barSaveOutcome() {
        #expect(EditorText.barSave(.saved, filterName: "A") == .saved)
        #expect(EditorText.barSave(.noBaseFilter, filterName: "A") == .needsName)
        #expect(EditorText.barSave(.refusedLoop, filterName: "A") == .refused("This would make ‘A’ include itself"))
        #expect(EditorText.barSave(.tooDeep, filterName: "A")
            == .refused("The filter is nested more than 32 levels deep."))
        #expect(EditorText.BarSaveOutcome.saved.runsPendingPick)
        #expect(!EditorText.BarSaveOutcome.needsName.runsPendingPick)
        #expect(!EditorText.BarSaveOutcome.refused("x").runsPendingPick)
    }

    /// A missing link imposes no constraint (ES §9): it is ignored, not "matches nothing".
    @Test func missingLinkHelp() {
        #expect(EditorText.missingLinkHelp == "Missing filter: this link is ignored until you choose a filter")
        #expect(!EditorText.missingLinkHelp.contains("matches nothing"))
    }
}
