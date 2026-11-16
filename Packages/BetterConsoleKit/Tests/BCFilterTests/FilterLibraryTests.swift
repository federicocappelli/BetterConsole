import Foundation
import Testing
@testable import BCFilter

final class FakeStorage: FilterLibraryStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    private var _saves = 0
    private var _movedAside = 0
    var failLoad = false
    var failMoveAside = false
    var failSave = false

    init(data: Data? = nil) { _data = data }

    var saves: Int { lock.withLock { _saves } }
    var movedAside: Int { lock.withLock { _movedAside } }

    func load() throws -> Data? {
        if failLoad { throw CocoaError(.fileReadCorruptFile) }
        return lock.withLock { _data }
    }
    func save(_ data: Data) throws {
        if failSave { throw CocoaError(.fileWriteOutOfSpace) }
        lock.withLock { _data = data; _saves += 1 }
    }
    func moveAside() throws {
        if failMoveAside { throw CocoaError(.fileWriteNoPermission) }
        lock.withLock { _data = nil; _movedAside += 1 }
    }
}

@MainActor @Suite struct FilterLibraryTests {
    private func cond(_ v: String) -> FilterExpression {
        .condition(FilterCondition(field: .process, match: .is, value: v))
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterLibraryTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func firstLaunchCreatesStarterOnce() {
        let storage = FakeStorage()
        let library = FilterLibrary(storage: storage)
        #expect(library.filters.map(\.name) == ["Errors and Faults"])
        #expect(library.filters[0].expression == .any([
            .condition(FilterCondition(field: .type, match: .is, value: "error")),
            .condition(FilterCondition(field: .type, match: .is, value: "fault")),
        ]))
        library.delete(id: library.filters[0].id)
        let again = FilterLibrary(storage: storage)
        #expect(again.filters.isEmpty)
        #expect(again.loadProblem == nil)
    }

    @Test func damagedLibraryMovedAside() {
        let storage = FakeStorage(data: Data("garbage".utf8))
        let library = FilterLibrary(storage: storage)
        #expect(storage.movedAside == 1)
        #expect(library.filters.isEmpty)
        #expect(library.loadProblem == "Your saved filters could not be read. They were set aside and BetterConsole started with an empty filter list.")
        library.acknowledgeLoadProblem()
        #expect(library.loadProblem == nil)
    }

    @Test func unreadableLibraryMovedAside() {
        let storage = FakeStorage()
        storage.failLoad = true
        let library = FilterLibrary(storage: storage)
        #expect(storage.movedAside == 1)
        #expect(library.filters.isEmpty)
        #expect(library.loadProblem != nil)
    }

    @Test func mutationsPersistAndReload() {
        let storage = FakeStorage()
        let library = FilterLibrary(storage: storage)
        let f = library.add(name: "Mine", expression: cond("A"))
        library.update(id: f.id, expression: cond("B"))
        let reloaded = FilterLibrary(storage: storage)
        #expect(reloaded.filter(id: f.id)?.expression == cond("B"))
    }

    @Test func uniqueNames() {
        let library = FilterLibrary(storage: FakeStorage())
        let a = library.add(name: "A", expression: nil)
        let b = library.add(name: "A", expression: nil)
        let c = library.add(name: "A", expression: nil)
        #expect([a.name, b.name, c.name] == ["A", "A 2", "A 3"])
    }

    @Test func filtersSortedNaturally() {
        let library = FilterLibrary(storage: FakeStorage())
        library.add(name: "Item 10", expression: nil)
        library.add(name: "Item 2", expression: nil)
        let names = library.filters.map(\.name)
        #expect(names.firstIndex(of: "Item 2")! < names.firstIndex(of: "Item 10")!)
    }

    @Test func renameUnique() {
        let library = FilterLibrary(storage: FakeStorage())
        let a = library.add(name: "A", expression: nil)
        let b = library.add(name: "B", expression: nil)
        library.rename(id: b.id, to: "A")
        #expect(library.filter(id: b.id)?.name == "A 2")
        library.rename(id: a.id, to: "A")
        #expect(library.filter(id: a.id)?.name == "A")
    }

    @Test func importReport() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = SavedFilter(name: "X", expression: cond("P"))
        let good = dir.appendingPathComponent("good.json")
        try FilterFile.encode(source).write(to: good)
        let bad = dir.appendingPathComponent("bad.json")
        try Data("{nope".utf8).write(to: bad)

        let library = FilterLibrary(storage: FakeStorage())
        let report = library.importFiles([good, bad])
        #expect(report.imported.count == 1)
        #expect(report.imported[0].id != source.id)
        #expect(report.imported[0].name == "X")
        #expect(report.rejected.count == 1)
        #expect(report.rejected[0].fileName == "bad.json")
        #expect(report.rejected[0].reason == FilterImportError.notJSON.description)

        let second = library.importFiles([good])
        #expect(second.imported[0].name == "X 2")
    }

    @Test func exportedFileIsNotLinked() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = FilterLibrary(storage: FakeStorage())
        let f = library.add(name: "X", expression: cond("P"))
        let url = dir.appendingPathComponent("x.json")
        try library.export(id: f.id, to: url)
        #expect(try FilterFile.decode(Data(contentsOf: url), fallbackName: "x").main.name == "X")
        try Data("changed".utf8).write(to: url)
        #expect(library.filter(id: f.id)?.name == "X")
        #expect(library.filter(id: f.id)?.expression == cond("P"))
    }

    @Test func fileStorageAtomicAndMoveAside() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FileFilterLibraryStorage(directory: dir)
        #expect(try storage.load() == nil)
        try storage.save(Data("one".utf8))
        try storage.save(Data("two".utf8))
        #expect(try storage.load() == Data("two".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["FilterLibrary.json"])
        try storage.moveAside()
        #expect(try storage.load() == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.count == 1)
        #expect(names[0].hasPrefix("FilterLibrary-damaged-") && names[0].hasSuffix(".json"))
    }

    @Test func starterNotRecreatedAfterDamagedLibrary() {
        let storage = FakeStorage(data: Data("garbage".utf8))
        _ = FilterLibrary(storage: storage)
        let again = FilterLibrary(storage: storage)
        #expect(again.filters.isEmpty)
        #expect(again.loadProblem == nil)
    }

    @Test func failedMoveAsideNeverWrites() {
        let storage = FakeStorage(data: Data("garbage".utf8))
        storage.failMoveAside = true
        let library = FilterLibrary(storage: storage)
        #expect(library.loadProblem == "Your saved filters could not be read, and BetterConsole could not set them aside. Changes to filters won't be saved until this is fixed.")
        library.add(name: "A", expression: nil)
        #expect(storage.saves == 0)
        #expect(library.filters.map(\.name) == ["A"])
    }

    @Test func saveProblemSetAndCleared() {
        let storage = FakeStorage()
        let library = FilterLibrary(storage: storage)
        #expect(library.saveProblem == nil)
        storage.failSave = true
        library.add(name: "A", expression: nil)
        #expect(library.saveProblem != nil)
        storage.failSave = false
        library.add(name: "B", expression: nil)
        #expect(library.saveProblem == nil)
    }

    @Test func renameToEmptyIsNoOp() {
        let library = FilterLibrary(storage: FakeStorage())
        let a = library.add(name: "A", expression: nil)
        library.rename(id: a.id, to: "   ")
        #expect(library.filter(id: a.id)?.name == "A")
    }

    @Test func uniqueNamesCaseInsensitive() {
        let library = FilterLibrary(storage: FakeStorage())
        library.add(name: "Errors", expression: nil)
        let b = library.add(name: "errors", expression: nil)
        #expect(b.name == "errors 2")
    }

    @Test func exportUnknownIDThrows() {
        let library = FilterLibrary(storage: FakeStorage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).json")
        #expect(throws: (any Error).self) { try library.export(id: UUID(), to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func moveAsideKeepsExistingBackup() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FileFilterLibraryStorage(directory: dir)
        for text in ["one", "two"] {
            try storage.save(Data(text.utf8))
            try storage.moveAside()
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("FilterLibrary-damaged-") }
        #expect(backups.count == 2)
        let contents = try backups.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
        #expect(Set(contents) == ["one", "two"])
    }

    // MARK: - Files in both formats (ES §7)

    private func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The format is found from the content, whatever the extension.
    @Test func detectsFormatByContent() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = try write(#"  {"name":"From JSON","expression":{"condition":{"field":"process","match":"is","value":"P"}}}"#,
                             "filter.txt", in: dir)
        let text = try write("process ==[c] \"Q\"\n", "Plain Text", in: dir)
        let library = FilterLibrary(storage: FakeStorage())
        let report = library.importFiles([json, text])
        #expect(report.rejected.isEmpty)
        #expect(report.imported.map(\.name) == ["From JSON", "Plain Text"])
        #expect(report.imported.map(\.expression) == [cond("P"), cond("Q")])
        // A header-less file is named after the file without its extension.
        let bare = try write("process ==[c] \"R\"", "Bare Filter.bcfilter", in: dir)
        #expect(library.importFiles([bare]).imported.map(\.name) == ["Bare Filter"])
        let bad = try write("// name: N\nprocess ==[c] \"a\"\nAND bogus == 1", "bad.bcfilter", in: dir)
        let rejected = library.importFiles([bad]).rejected
        #expect(rejected.count == 1)
        #expect(rejected.first?.reason.hasPrefix("Line 3: ") == true)
    }

    /// A library holding `filters` as they are, duplicates included (as Phase 3 imports could).
    private func library(holding filters: [SavedFilter]) throws -> FilterLibrary {
        struct File: Encodable { var version = 1; var starterCreated = true; var filters: [SavedFilter] }
        return FilterLibrary(storage: FakeStorage(data: try JSONEncoder().encode(File(filters: filters))))
    }

    /// ES §7.2: links resolve to the file's own (renamed) linked filters first, then to
    /// existing filters (exact case first), and are otherwise reported missing.
    @Test func importResolvesBundleThenExistingThenMissing() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = """
            // BetterConsole filter
            // version: 1
            // name: Main
            filter == "Noise" AND filter == "Heartbeat" AND filter == "errors"
            AND filter == "WARNINGS" AND NOT filter == "Gone"

            // filter: Noise
            filter == "Gone" OR filter == "Heartbeat" OR filter == "alpha"

            // filter: Alpha
            process ==[c] "a"

            // filter: ALPHA
            process ==[c] "b"
            """
        let json = #"""
            {"name":"Main","expression":{"all":[{"link":{"name":"Noise"}},{"link":{"name":"Heartbeat"}},
              {"link":{"name":"errors"}},{"link":{"name":"WARNINGS"}},{"not":{"link":{"name":"Gone"}}}]},
             "linked":[
              {"name":"Noise","expression":{"any":[{"link":{"name":"Gone"}},{"link":{"name":"Heartbeat"}},{"link":{"name":"alpha"}}]}},
              {"name":"Alpha","expression":{"condition":{"field":"process","match":"is","value":"a"}}},
              {"name":"ALPHA","expression":{"condition":{"field":"process","match":"is","value":"b"}}}]}
            """#
        for (contents, fileName) in [(text, "main.bcfilter"), (json, "main.json")] {
            let noise = SavedFilter(name: "Noise", expression: cond("old noise"))
            let heartbeat = SavedFilter(name: "Heartbeat", expression: cond("h"))
            let upper = SavedFilter(name: "Errors", expression: cond("E"))
            let lower = SavedFilter(name: "errors", expression: cond("e"))
            let warnings = SavedFilter(name: "Warnings", expression: cond("w"))
            let library = try library(holding: [noise, heartbeat, upper, lower, warnings])
            let before = Set(library.filters.map(\.id))
            let report = library.importFiles([try write(contents, fileName, in: dir)])
            #expect(report.rejected.isEmpty, "\(fileName)")
            #expect(Set(report.imported.map(\.name)) == ["Main", "Noise 2", "Alpha", "ALPHA 2"], "\(fileName)")
            let byName = Dictionary(uniqueKeysWithValues: report.imported.map { ($0.name, $0) })
            let main = try #require(byName["Main"])
            guard case .all(let links) = main.expression, links.count == 5,
                  case .link(let toNoise) = links[0], case .link(let toHeartbeat) = links[1],
                  case .link(let toErrors) = links[2], case .link(let toWarnings) = links[3],
                  case .not(.link(let toGone)) = links[4]
            else { Issue.record("unexpected tree \(String(describing: main.expression))"); continue }
            #expect(toNoise == byName["Noise 2"]?.id, "bundled, renamed, wins over existing Noise")
            #expect(toHeartbeat == heartbeat.id, "existing")
            #expect(toErrors == lower.id, "existing, exact case first")
            #expect(toWarnings == warnings.id, "existing, any case")
            #expect(library.filter(id: toGone) == nil && !before.contains(toGone), "missing")
            // Inside the bundle: exact case first among bundled filters.
            guard case .any(let inner) = byName["Noise 2"]?.expression, inner.count == 3,
                  case .link(let innerGone) = inner[0], case .link(let innerHeartbeat) = inner[1],
                  case .link(let innerAlpha) = inner[2]
            else { Issue.record("unexpected bundle tree"); continue }
            #expect(innerGone == toGone)
            #expect(innerHeartbeat == heartbeat.id)
            #expect(innerAlpha == byName["Alpha"]?.id)
            #expect(report.missingLinks.map { "\($0.filter) → \($0.link)" }.sorted()
                == ["Main → Gone", "Noise 2 → Gone"], "\(fileName)")
            // Existing filters are untouched.
            #expect(library.filter(id: noise.id)?.expression == cond("old noise"))
        }
    }

    @Test func loopingBundleRejectedOnImport() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write("// name: M\nfilter == \"A\"\n// filter: A\nfilter == \"B\"\n// filter: B\nfilter == \"A\"",
                            "loop.bcfilter", in: dir)
        let library = FilterLibrary(storage: FakeStorage())
        let count = library.filters.count
        let report = library.importFiles([url])
        #expect(report.imported.isEmpty)
        #expect(report.rejected.map(\.reason) == [FilterImportError.linkLoop.description])
        #expect(library.filters.count == count)
    }

    @Test func editorDecodeAddsLinkedAndReturnsMain() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write("""
            // name: Editor Main
            process ==[c] "P" AND NOT filter == "Noise" AND filter == "Gone"
            // filter: Noise
            filter == "Inner" OR filter == "Lost"
            // filter: Inner
            category ==[c] "c"
            """, "e.bcfilter", in: dir)
        let library = try library(holding: [SavedFilter(name: "Noise", expression: cond("old"))])
        let result = try library.decodeForEditor(url)
        let noise = try #require(library.filters.first { $0.name == "Noise 2" })
        let inner = try #require(library.filters.first { $0.name == "Inner" })
        guard case .all(let members) = result.expression, members.count == 3,
              case .link(let gone) = members[2]
        else { Issue.record("unexpected tree \(String(describing: result.expression))"); return }
        #expect(members[0] == cond("P"))
        #expect(members[1] == .not(.link(noise.id)))
        #expect(library.filter(id: gone) == nil)
        guard case .any(let inNoise) = noise.expression, inNoise.count == 2 else {
            Issue.record("unexpected bundle tree"); return
        }
        #expect(inNoise[0] == .link(inner.id))
        // Unresolved links of the main filter and of the bundled filters it added are reported.
        #expect(result.missingLinks.map { "\($0.filter) → \($0.link)" }
            == ["Editor Main → Gone", "Noise 2 → Lost"])
        #expect(!library.filters.contains { $0.name == "Editor Main" })
        #expect(library.filters.count == 3)
        let bad = try write("// name: N\n(", "bad.bcfilter", in: dir)
        #expect(throws: FilterImportError.self) { try library.decodeForEditor(bad) }
        #expect(library.filters.count == 3)
    }

    /// A link by id to a filter the file's author no longer had reads as such in the report.
    @Test func missingLinkByIDReportedInWords() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write(#"{"name":"M","expression":{"link":{"id":"6F1C2B3A-0000-4000-8000-000000000009"}}}"#,
                            "m.json", in: dir)
        let report = FilterLibrary(storage: FakeStorage()).importFiles([url])
        #expect(report.missingLinks.map(\.link) == ["a filter that no longer existed when this file was exported"])
    }

    @Test func editorExportWithBlankNameUsesUntitled() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = FilterLibrary(storage: FakeStorage())
        for format in FilterFileFormat.allCases {
            let url = dir.appendingPathComponent("blank.\(format.fileExtension)")
            try library.export(expression: cond("x"), name: "  ", to: url, format: format)
            let d = try FilterFile.decode(Data(contentsOf: url), fallbackName: "file name")
            #expect(d.main.name == "Untitled", "\(format)")
            #expect(d.main.expression == cond("x"))
        }
    }

    /// Export writes the saved filter and every filter it reaches through links, and nothing else.
    @Test func exportWritesClosureInBothFormats() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FilterLibrary(storage: FakeStorage())
        let c = source.add(name: "C", expression: cond("c"))
        let b = source.add(name: "B", expression: .any([.link(c.id), cond("b")]))
        source.add(name: "Unrelated", expression: cond("u"))
        let a = source.add(name: "A", expression: .all([.link(b.id), .not(.link(c.id))]))
        for format in FilterFileFormat.allCases {
            let url = dir.appendingPathComponent("a.\(format.fileExtension)")
            try source.export(id: a.id, to: url, format: format)
            let d = try FilterFile.decode(Data(contentsOf: url), fallbackName: "x")
            #expect(d.main.name == "A")
            #expect(d.linked.map(\.name) == ["B", "C"], "\(format)")

            let target = FilterLibrary(storage: FakeStorage())
            let report = target.importFiles([url])
            #expect(report.missingLinks.isEmpty)
            let byName = Dictionary(uniqueKeysWithValues: report.imported.map { ($0.name, $0) })
            let (ta, tb, tc) = (try #require(byName["A"]), try #require(byName["B"]), try #require(byName["C"]))
            #expect(ta.expression == .all([.link(tb.id), .not(.link(tc.id))]))
            #expect(tb.expression == .any([.link(tc.id), cond("b")]))
            #expect(tc.expression == cond("c"))

            // The editor's export writes its current content under the name given.
            let editorURL = dir.appendingPathComponent("editor.\(format.fileExtension)")
            try source.export(expression: .link(c.id), name: "Untitled", to: editorURL, format: format)
            let e = try FilterFile.decode(Data(contentsOf: editorURL), fallbackName: "x")
            #expect(e.main.name == "Untitled")
            #expect(e.linked.map(\.name) == ["C"])
        }
    }
}
