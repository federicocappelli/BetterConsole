import Foundation
import Testing
@testable import BCFilter

/// Opened files have filter states like devices, under `file:` ids, but those are never saved:
/// a file window's filter lasts while the app runs.
@MainActor @Suite struct FileFilterPersistenceTests {
    final class Persistence: DeviceFilterPersistence {
        var stored: [String: DeviceFilterState] = [:]
        func load() -> [String: DeviceFilterState] { stored }
        func save(_ states: [String: DeviceFilterState]) { stored = states }
    }

    final class Storage: FilterLibraryStorage, @unchecked Sendable {
        var data: Data?
        func load() throws -> Data? { data }
        func save(_ data: Data) throws { self.data = data }
        func moveAside() throws { data = nil }
    }

    let condition = FilterExpression.condition(FilterCondition(field: .process, match: .is, value: "a"))

    @Test func fileIDsAreNotSaved() {
        let persistence = Persistence()
        let library = FilterLibrary(storage: Storage())
        let workspace = FilterWorkspace(library: library, persistence: persistence)
        workspace.setExpression(condition, for: "file:/tmp/a.log")
        workspace.setExpression(condition, for: "local")
        #expect(workspace.state(for: "file:/tmp/a.log").expression == condition)
        #expect(Set(persistence.stored.keys) == ["local"])

        let saved = workspace.saveAs(name: "F", for: "file:/tmp/a.log")
        #expect(library.filter(id: saved.id) != nil)  // the saved filter itself is kept
        #expect(persistence.stored["file:/tmp/a.log"] == nil)
    }

    /// A file id that slipped into storage (an older build) is not restored.
    @Test func fileIDsAreNotRestored() {
        let persistence = Persistence()
        persistence.stored = [
            "file:/tmp/a.log": DeviceFilterState(expression: condition, isEdited: true),
            "local": DeviceFilterState(expression: condition, isEdited: true),
        ]
        let workspace = FilterWorkspace(library: FilterLibrary(storage: Storage()), persistence: persistence)
        #expect(workspace.state(for: "file:/tmp/a.log") == .empty)
        #expect(workspace.state(for: "local").expression == condition)
    }
}
