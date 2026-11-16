import Foundation
import BCFilter
import BCMobileDevice
import BCStore
import BCStreaming
import BCTransport

/// Composition root: the only place transports and discoveries are registered.
@MainActor
final class AppEnvironment {
    let budget: MemoryBudget
    let registry: SessionRegistry
    let library: FilterLibrary
    let workspace: FilterWorkspace
    private var discoveryTask: Task<Void, Never>?

    init(
        budget: MemoryBudget, registry: SessionRegistry,
        library: FilterLibrary, workspace: FilterWorkspace
    ) {
        self.budget = budget
        self.registry = registry
        self.library = library
        self.workspace = workspace
        // Sessions start with their device's filter; workspace changes reach live sessions.
        connect(registry: registry, workspace: workspace)
        // An open filter editor counts its preview on the device's new session once the
        // device returns (ES §8.1).
        registry.addSessionCreatedHandler { session in
            FilterEditorWindows.updateSession(session, forDevice: session.device.id)
        }
    }

    /// Starts device discovery for the app's lifetime. Idempotent.
    func start() {
        guard discoveryTask == nil else { return }
        let registry = self.registry
        discoveryTask = Task { await registry.run() }
    }

    /// With `BETTERCONSOLE_PROBE=<file>`: records main-thread and throughput figures to the
    /// file and starts streaming this Mac as soon as it is discovered (no UI scripting, which
    /// would switch on the app's accessibility mode and skew the figures). With
    /// `BETTERCONSOLE_PROBE_DEVICES=all` as well, every available device streams, for checking
    /// a release build without the UI.
    func startProbeIfRequested() {
        let registry = self.registry
        guard MainThreadProbe.startIfRequested(
            counters: {
                var c = MainThreadProbe.Counters()
                for row in registry.rows {
                    guard let session = registry.session(for: row.id) else { continue }
                    c.received += session.appendedCount + session.droppedCount
                    c.dropped += session.droppedCount
                    c.stored += session.store.count
                    c.estimatedBytes += session.store.estimatedBytes
                }
                return c
            },
            sessions: {
                registry.rows.compactMap { row in
                    registry.session(for: row.id).map {
                        "\(row.device.name) [\(row.id)]: \($0.state), \($0.appendedCount) received, "
                            + ($0.filter == nil ? "no filter" : "filter applied, \($0.rows.count) rows shown")
                    }
                }
            })
        else { return }
        let probeFilter = Self.probeFilter()
        let all = ProcessInfo.processInfo.environment["BETTERCONSOLE_PROBE_DEVICES"] == "all"
        Task {
            for _ in 0..<100 {
                for row in registry.rows where all ? row.isAvailable : row.id == "local" {
                    if let session = registry.session(for: row.id), session.state == .idle {
                        if row.id == "local", let probeFilter {
                            session.setFilter(probeFilter.expression)
                        }
                        session.start()
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// With `BETTERCONSOLE_PROBE_FILTER=<exported filter file>`: the filter to apply to the
    /// `local` session before the probe starts streaming it.
    private static func probeFilter() -> SavedFilter? {
        guard let path = ProcessInfo.processInfo.environment["BETTERCONSOLE_PROBE_FILTER"],
            let data = FileManager.default.contents(atPath: path)
        else { return nil }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return try? FilterFile.decode(data, fallbackName: name).main
    }

    #if DEBUG
    /// Debug only: a small budget exercises eviction from the front of the table.
    /// Wins over the stored setting when present.
    static var debugLimitOverrideBytes: Int? {
        ProcessInfo.processInfo.environment["BETTERCONSOLE_MEMORY_LIMIT_MB"]
            .flatMap(Int.init).flatMap { $0 > 0 ? $0 * 1024 * 1024 : nil }
    }
    #endif

    static func live() -> AppEnvironment {
        let budget = MemoryBudget()
        let stored = UserDefaults.standard.object(forKey: MemorySetting.key) as? Double
        budget.limitBytes = MemorySetting.bytes(forGB: stored ?? MemorySetting.defaultGB)
        #if DEBUG
        if let override = debugLimitOverrideBytes { budget.limitBytes = override }
        #endif
        let registry = SessionRegistry(
            discoveries: [
                LocalMacDiscovery(),
                SimulatorDiscovery(),
                MobileDeviceDiscovery(),
            ],
            transports: [
                ProcessLogTransport(),
                MobileDeviceLogTransport(),
            ],
            budget: budget)
        let library = FilterLibrary(storage: FileFilterLibraryStorage(directory: libraryDirectory()))
        let workspace = FilterWorkspace(
            library: library, persistence: UserDefaultsDeviceFilterPersistence())
        return AppEnvironment(
            budget: budget, registry: registry, library: library, workspace: workspace)
    }

    /// `~/Library/Application Support/BetterConsole/`, created if missing.
    private static func libraryDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("BetterConsole", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
