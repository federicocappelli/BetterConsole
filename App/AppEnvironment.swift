import Foundation
import BCMobileDevice
import BCStore
import BCStreaming
import BCTransport

/// Composition root: the only place transports and discoveries are registered.
@MainActor
final class AppEnvironment {
    let budget: MemoryBudget
    let registry: SessionRegistry
    private var discoveryTask: Task<Void, Never>?

    init(budget: MemoryBudget, registry: SessionRegistry) {
        self.budget = budget
        self.registry = registry
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
                        "\(row.device.name) [\(row.id)]: \($0.state), \($0.appendedCount) received"
                    }
                }
            })
        else { return }
        let all = ProcessInfo.processInfo.environment["BETTERCONSOLE_PROBE_DEVICES"] == "all"
        Task {
            for _ in 0..<100 {
                for row in registry.rows where all ? row.isAvailable : row.id == "local" {
                    if let session = registry.session(for: row.id), session.state == .idle {
                        session.start()
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
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
        return AppEnvironment(budget: budget, registry: registry)
    }
}
