import Synchronization
import BCModel

/// One transport batch with the filter verdict computed off-main (spec §8.2).
public struct TaggedBatch: Sendable {
    public var entries: [LogEntry]
    /// One verdict per entry, or nil when the batch has not been checked against a filter.
    public var matches: [Bool]?
    /// The `FilterSlot` generation the verdicts were computed against (0: never checked).
    public var generation: UInt64

    public init(entries: [LogEntry], matches: [Bool]?, generation: UInt64) {
        precondition(matches == nil || matches?.count == entries.count)
        self.entries = entries
        self.matches = matches
        self.generation = generation
    }

    /// A batch straight from the transport, not yet checked.
    init(unchecked entries: [LogEntry]) {
        self.init(entries: entries, matches: nil, generation: 0)
    }

    var count: Int { entries.count }

    /// Whether the drain may index this batch under filter generation `generation`.
    func isChecked(against generation: UInt64) -> Bool {
        self.generation == generation && matches != nil
    }

    /// The first `n` entries, verdicts kept aligned.
    func prefix(_ n: Int) -> TaggedBatch {
        TaggedBatch(
            entries: Array(entries[..<n]), matches: matches.map { Array($0[..<n]) },
            generation: generation)
    }

    /// Everything after the first `n` entries, verdicts kept aligned.
    func dropFirst(_ n: Int) -> TaggedBatch {
        TaggedBatch(
            entries: Array(entries[n...]), matches: matches.map { Array($0[n...]) },
            generation: generation)
    }
}

/// Thread-safe hand-off between the off-main stream reader, the off-main filter checker and
/// the main-actor drain loop (spec §6.5.1, §8.2). Holds at most `capacity` entries, checked or
/// not; when full, incoming excess is dropped and counted instead of blocking the reader.
public final class BoundedBatchQueue: Sendable {
    private struct Queued {
        /// Identifies the batch for `completeCheck`; a batch cut in two gets new ids.
        var id: UInt64
        var batch: TaggedBatch
    }

    private struct State {
        var batches: [Queued] = []
        var count = 0
        var dropped = 0
        var nextID: UInt64 = 0

        mutating func makeID() -> UInt64 {
            nextID += 1
            return nextID
        }
    }

    let capacity: Int
    private let state = Mutex(State())
    /// Signals the checker that there may be work: a push, or a filter change (`wake()`).
    let wakeups: AsyncStream<Void>
    private let wakeup: AsyncStream<Void>.Continuation

    public init(capacity: Int = 200_000) {
        precondition(capacity > 0)
        self.capacity = capacity
        (wakeups, wakeup) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit { wakeup.finish() }

    /// Entries queued now.
    var count: Int { state.withLock { $0.count } }

    public func push(_ batch: TaggedBatch) {
        guard batch.count > 0 else { return }
        state.withLock { s in
            let room = max(0, capacity - s.count)
            let kept = min(room, batch.count)
            if kept == batch.count {
                s.batches.append(Queued(id: s.makeID(), batch: batch))
            } else if kept > 0 {
                s.batches.append(Queued(id: s.makeID(), batch: batch.prefix(kept)))
            }
            s.count += kept
            s.dropped += batch.count - kept
        }
        wakeup.yield()
    }

    /// Wakes the checker, e.g. because the filter changed and queued verdicts went stale.
    func wake() { wakeup.yield() }

    /// Returns up to `max` of the oldest queued entries, in their batches (the rest stay
    /// queued; a batch cut in two keeps its verdicts aligned), and the number of entries
    /// dropped since the last drain, and resets the dropped count. With `checkedAgainst`, only
    /// the leading batches already checked against that filter generation are taken.
    public func drain(
        max: Int = .max, checkedAgainst generation: UInt64? = nil
    ) -> (batches: [TaggedBatch], dropped: Int) {
        precondition(max > 0)
        return state.withLock { s in
            let dropped = s.dropped
            s.dropped = 0
            var ready = s.batches.count
            if let generation {
                ready = s.batches.firstIndex { !$0.batch.isChecked(against: generation) }
                    ?? s.batches.count
            }
            if ready == s.batches.count, s.count <= max {
                // Hand the batches over without keeping a reference, so the drain can stamp
                // entries in place without copying them.
                let all = s.batches.map(\.batch)
                s.batches = []
                s.count = 0
                return (all, dropped)
            }
            var taken = 0
            var whole = 0
            while whole < ready, taken + s.batches[whole].batch.count <= max {
                taken += s.batches[whole].batch.count
                whole += 1
            }
            var out = s.batches[..<whole].map(\.batch)
            s.batches.removeFirst(whole)
            if whole < ready, taken < max {
                let cut = max - taken
                out.append(s.batches[0].batch.prefix(cut))
                s.batches[0] = Queued(id: s.makeID(), batch: s.batches[0].batch.dropFirst(cut))
                taken += cut
            }
            s.count -= taken
            return (out, dropped)
        }
    }

    /// Discards everything queued and the dropped count.
    func removeAll() {
        state.withLock { s in
            s.batches = []
            s.count = 0
            s.dropped = 0
        }
    }

    /// The oldest batch not yet checked against filter generation `generation`, for the
    /// checker. It stays queued (and counted) while being checked.
    func nextToCheck(against generation: UInt64) -> (id: UInt64, entries: [LogEntry])? {
        state.withLock { s in
            s.batches.first { !$0.batch.isChecked(against: generation) }
                .map { ($0.id, $0.batch.entries) }
        }
    }

    /// Stores the checker's verdicts for batch `id`, unless the batch has since been drained,
    /// cleared or cut (then the verdicts are dropped and what is left is checked again).
    func completeCheck(id: UInt64, matches: [Bool], generation: UInt64) {
        state.withLock { s in
            guard let i = s.batches.firstIndex(where: { $0.id == id }),
                  s.batches[i].batch.count == matches.count
            else { return }
            s.batches[i].batch.matches = matches
            s.batches[i].batch.generation = generation
        }
    }
}
