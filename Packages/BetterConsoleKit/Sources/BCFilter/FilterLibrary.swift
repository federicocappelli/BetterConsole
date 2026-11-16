import Foundation
import Observation

public protocol FilterLibraryStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func moveAside() throws
}

public struct FileFilterLibraryStorage: FilterLibraryStorage {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private var fileURL: URL { directory.appendingPathComponent("FilterLibrary.json") }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func moveAside() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var target = directory.appendingPathComponent("FilterLibrary-damaged-\(stamp).json")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("FilterLibrary-damaged-\(stamp)-\(n).json")
            n += 1
        }
        try FileManager.default.moveItem(at: fileURL, to: target)
    }
}

public enum FilterLibraryError: Error, Equatable {
    case unknownFilter
}

@MainActor @Observable
public final class FilterLibrary {
    public struct ImportReport: Sendable {
        public var imported: [SavedFilter]
        public var rejected: [(fileName: String, reason: String)]
        /// Links no bundled or existing filter satisfies: the imported filter (by its name in
        /// the library) and the name it links. They stay in the filter as missing links.
        public var missingLinks: [(filter: String, link: String)]
    }

    /// What the editor's Import loads: the main filter's tree, and the links in it or in the
    /// bundled filters it added that nothing resolved (ES §7.2).
    public struct EditorImport: Sendable {
        public var expression: FilterExpression?
        public var missingLinks: [(filter: String, link: String)]
    }

    private struct LibraryFile: Codable {
        var version: Int
        var starterCreated: Bool
        var filters: [SavedFilter]
    }

    public static let notSetAsideMessage =
        "Your saved filters could not be read, and BetterConsole could not set them aside. Changes to filters won't be saved until this is fixed."
    public static let damagedMessage =
        "Your saved filters could not be read. They were set aside and BetterConsole started with an empty filter list."

    public private(set) var filters: [SavedFilter] = []
    public private(set) var loadProblem: String?
    public private(set) var saveProblem: String?

    @ObservationIgnored private let storage: any FilterLibraryStorage
    @ObservationIgnored private var starterCreated = false
    @ObservationIgnored private var savingEnabled = true

    public init(storage: any FilterLibraryStorage) {
        self.storage = storage
        do {
            if let data = try storage.load() {
                let file = try JSONDecoder().decode(LibraryFile.self, from: data)
                filters = file.filters
                starterCreated = file.starterCreated
            } else {
                filters = [Self.starter()]
                starterCreated = true
                persist()
            }
        } catch {
            filters = []
            starterCreated = true
            do {
                try storage.moveAside()
                loadProblem = Self.damagedMessage
                persist()
            } catch {
                // Never overwrite the damaged file we could not set aside.
                savingEnabled = false
                loadProblem = Self.notSetAsideMessage
            }
        }
        sortFilters()
    }

    private static func starter() -> SavedFilter {
        SavedFilter(
            name: "Errors and Faults",
            expression: .any([
                .condition(FilterCondition(field: .type, match: .is, value: "error")),
                .condition(FilterCondition(field: .type, match: .is, value: "fault")),
            ]))
    }

    public func acknowledgeLoadProblem() { loadProblem = nil }

    public func filter(id: UUID) -> SavedFilter? { filters.first { $0.id == id } }

    @discardableResult
    public func add(name: String, expression: FilterExpression?) -> SavedFilter {
        let filter = SavedFilter(name: uniqueName(name), expression: expression)
        filters.append(filter)
        commit()
        return filter
    }

    public func update(id: UUID, expression: FilterExpression?) {
        guard let i = filters.firstIndex(where: { $0.id == id }) else { return }
        filters[i].expression = expression
        commit()
    }

    public func rename(id: UUID, to name: String) {
        guard let i = filters.firstIndex(where: { $0.id == id }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        filters[i].name = uniqueName(name, ignoring: id)
        commit()
    }

    /// Removes only this filter. Links to it in other filters keep its id and become missing
    /// links (ES §9); `FilterWorkspace.delete` tells the devices that used them.
    public func delete(id: UUID) {
        filters.removeAll { $0.id == id }
        commit()
    }

    /// Imports each file's filter and the linked filters bundled with it (ES §7.2).
    public func importFiles(_ urls: [URL]) -> ImportReport {
        var report = ImportReport(imported: [], rejected: [], missingLinks: [])
        for url in urls {
            let fileName = url.lastPathComponent
            do {
                let added = insert(try read(url), includingMain: true)
                report.imported += added.filters
                report.missingLinks += added.missing
            } catch let error as FilterImportError {
                report.rejected.append((fileName, error.description))
            } catch {
                report.rejected.append((fileName, error.localizedDescription))
            }
        }
        if !report.imported.isEmpty { commit() }
        return report
    }

    /// For the editor's Import: adds the file's bundled linked filters to the library and
    /// returns the main filter's tree with its links resolved (ES §7.2).
    public func decodeForEditor(_ url: URL) throws -> EditorImport {
        let added = insert(try read(url), includingMain: false)
        if !added.filters.isEmpty { commit() }
        return EditorImport(expression: added.main, missingLinks: added.missing)
    }

    /// Writes the saved filter and every filter it reaches through links.
    public func export(id: UUID, to url: URL, format: FilterFileFormat = .json) throws {
        guard let filter = filter(id: id) else { throw FilterLibraryError.unknownFilter }
        try write(filter, to: url, format: format)
    }

    /// Writes the editor's current content under `name`, with the filters it links.
    public func export(
        expression: FilterExpression?, name: String, to url: URL, format: FilterFileFormat
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let main = SavedFilter(name: trimmed.isEmpty ? "Untitled" : name, expression: expression)
        try write(main, to: url, format: format)
    }

    /// How the report names a link written by id: its filter was already gone at export.
    static let missingAtExport = "a filter that no longer existed when this file was exported"

    private func write(_ filter: SavedFilter, to url: URL, format: FilterFileFormat) throws {
        let linked = FilterLinks.closure(of: filter.expression, in: filters)
        try FilterFile.encode(filter, linked: linked, format: format).write(to: url, options: .atomic)
    }

    private func read(_ url: URL) throws -> DecodedFilterFile {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= FilterFile.maxBytes else { throw FilterImportError.tooLarge }
        let data = try Data(contentsOf: url)
        return try FilterFile.decode(data, fallbackName: url.deletingPathExtension().lastPathComponent)
    }

    /// Adds the file's linked filters (and its main filter when `includingMain`) under unique
    /// names, then resolves links by name: to a bundled filter first, then to an existing one
    /// (exact case first), else left missing. Does not commit.
    private func insert(
        _ file: DecodedFilterFile, includingMain: Bool
    ) -> (filters: [SavedFilter], main: FilterExpression?, missing: [(filter: String, link: String)]) {
        let existing = filters
        var added: [SavedFilter] = []
        func add(_ f: SavedFilter) {
            let new = SavedFilter(name: uniqueName(f.name), expression: f.expression)
            filters.append(new)
            added.append(new)
        }
        if includingMain { add(file.main) }
        let bundleStart = added.count
        file.linked.forEach(add)

        let ids = Set(filters.map(\.id))
        func resolve(_ name: String) -> UUID? {
            if let i = file.bundleIndex(of: name) { return added[bundleStart + i].id }
            return (existing.first { $0.name == name }
                ?? existing.first { $0.name.lowercased() == name.lowercased() })?.id
        }
        func resolved(_ e: FilterExpression?, owner: String, missing: inout [(filter: String, link: String)]) -> FilterExpression? {
            var reported = Set<String>()
            func walk(_ e: FilterExpression) -> FilterExpression {
                switch e {
                case .condition: return e
                case .all(let xs): return .all(xs.map(walk))
                case .any(let xs): return .any(xs.map(walk))
                case .not(let x): return .not(walk(x))
                case .link(let id):
                    if let name = file.linkName(id) {
                        if let target = resolve(name) { return .link(target) }
                        if reported.insert(name).inserted { missing.append((owner, name)) }
                    } else if !ids.contains(id), reported.insert(Self.missingAtExport).inserted {
                        missing.append((owner, Self.missingAtExport))
                    }
                    return e
                }
            }
            return e.map(walk)
        }

        var missing: [(filter: String, link: String)] = []
        // Not added, the main filter (the editor's content) is reported under its file name.
        let editorMain = includingMain
            ? nil : resolved(file.main.expression, owner: file.main.name, missing: &missing)
        for (k, f) in added.enumerated() {
            let e = resolved(f.expression, owner: f.name, missing: &missing)
            added[k].expression = e
            if let i = filters.firstIndex(where: { $0.id == f.id }) { filters[i].expression = e }
        }
        return (added, includingMain ? added[0].expression : editorMain, missing)
    }

    // MARK: - Private

    private func uniqueName(_ proposed: String, ignoring: UUID? = nil) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled" : trimmed
        let taken = Set(filters.filter { $0.id != ignoring }.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    private func sortFilters() {
        filters.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func commit() {
        sortFilters()
        persist()
    }

    private func persist() {
        let file = LibraryFile(version: 1, starterCreated: starterCreated, filters: filters)
        guard savingEnabled else { return }
        do {
            try storage.save(try JSONEncoder().encode(file))
            saveProblem = nil
        } catch {
            saveProblem = "Your filters could not be saved. Changes may be lost when BetterConsole quits."
        }
    }
}
