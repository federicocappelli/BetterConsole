import Foundation
import BCModel

/// One global memory budget shared by all device stores. Evicts the oldest entries across all
/// registered stores until the total estimated size fits `limitBytes`.
@MainActor
public final class MemoryBudget {
    public static let defaultLimit = 4 * 1024 * 1024 * 1024
    private static let maxChunk = 1_000

    private struct WeakStore {
        weak var store: LogStore?
        let onEvict: @MainActor () -> Void
    }
    private var stores: [WeakStore] = []

    /// Number of live registered stores (for tests).
    var registeredCount: Int { stores.reduce(0) { $0 + ($1.store == nil ? 0 : 1) } }

    public var limitBytes: Int { didSet { enforce() } }

    public init(limitBytes: Int = MemoryBudget.defaultLimit) {
        self.limitBytes = limitBytes
    }

    /// Registers `store`; `onEvict` is called once per `enforce()` pass that removed entries
    /// from it, after the pass. Re-registering a store replaces its callback.
    public func register(_ store: LogStore, onEvict: @escaping @MainActor () -> Void = {}) {
        stores.removeAll { $0.store == nil || $0.store === store }
        stores.append(WeakStore(store: store, onEvict: onEvict))
    }

    public func unregister(_ store: LogStore) {
        stores.removeAll { $0.store == nil || $0.store === store }
    }

    /// Cheap when under the limit: one sum over the registered stores.
    public func enforce() {
        stores.removeAll { $0.store == nil }
        var live = stores.compactMap(\.store)
        var total = live.reduce(0) { $0 + $1.estimatedBytes }
        guard total > limitBytes else { return }
        var evicted: Set<ObjectIdentifier> = []
        defer {
            for entry in stores {
                if let store = entry.store, evicted.contains(ObjectIdentifier(store)) {
                    entry.onEvict()
                }
            }
        }

        while total > limitBytes {
            // Find the store with the oldest entry and the next-oldest date among the others.
            var victim: LogStore?
            var victimDate = Date.distantFuture
            var nextDate = Date.distantFuture
            for store in live {
                guard let d = store.oldestDate else { continue }
                if d < victimDate {
                    nextDate = victimDate
                    victimDate = d
                    victim = store
                } else if d < nextDate {
                    nextDate = d
                }
            }
            guard let victim else { return }

            // Remove a chunk of entries older than the next store's oldest (at least one),
            // never freeing more than needed.
            let excess = total - limitBytes
            let n = victim.evictionCount(
                coveringBytes: excess, maxCount: Self.maxChunk, olderThan: nextDate)
            let before = victim.estimatedBytes
            victim.removeOldest(n)
            evicted.insert(ObjectIdentifier(victim))
            total -= before - victim.estimatedBytes
            if victim.count == 0 { live.removeAll { $0 === victim } }
        }
    }
}
