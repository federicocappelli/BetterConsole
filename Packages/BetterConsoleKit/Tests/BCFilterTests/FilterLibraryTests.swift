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
        try Data("nope".utf8).write(to: bad)

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
        #expect(try FilterFile.decode(Data(contentsOf: url)).name == "X")
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
}
