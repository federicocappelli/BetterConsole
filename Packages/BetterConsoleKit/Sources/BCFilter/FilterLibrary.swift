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

    public func delete(id: UUID) {
        filters.removeAll { $0.id == id }
        commit()
    }

    public func importFiles(_ urls: [URL]) -> ImportReport {
        var report = ImportReport(imported: [], rejected: [])
        for url in urls {
            let fileName = url.lastPathComponent
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= FilterFile.maxBytes else { throw FilterImportError.tooLarge }
                let data = try Data(contentsOf: url)
                let decoded = try FilterFile.decode(data)
                let filter = SavedFilter(
                    name: uniqueName(decoded.name), expression: decoded.expression)
                filters.append(filter)
                report.imported.append(filter)
            } catch let error as FilterImportError {
                report.rejected.append((fileName, error.description))
            } catch {
                report.rejected.append((fileName, error.localizedDescription))
            }
        }
        if !report.imported.isEmpty { commit() }
        return report
    }

    public func export(id: UUID, to url: URL) throws {
        guard let filter = filter(id: id) else { throw FilterLibraryError.unknownFilter }
        try FilterFile.encode(filter).write(to: url, options: .atomic)
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
