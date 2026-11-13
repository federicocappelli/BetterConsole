import Synchronization
import BCModel

/// Thread-safe hand-off between the off-main stream reader and the main-actor drain loop
/// (spec §6.5.1). Holds at most `capacity` entries; when full, incoming excess is dropped and
/// counted instead of blocking the reader.
public final class BoundedBatchQueue: Sendable {
    private struct State {
        var entries: [LogEntry] = []
        var dropped = 0
    }

    private let capacity: Int
    private let state = Mutex(State())

    public init(capacity: Int = 200_000) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func push(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        state.withLock { s in
            let room = max(0, capacity - s.entries.count)
            if entries.count <= room {
                s.entries.append(contentsOf: entries)
            } else {
                s.entries.append(contentsOf: entries.prefix(room))
                s.dropped += entries.count - room
            }
        }
    }

    /// Returns up to `max` of the oldest queued entries (the rest stay queued) and the number of
    /// entries dropped since the last drain, and resets the dropped count.
    public func drain(max: Int = .max) -> (entries: [LogEntry], dropped: Int) {
        precondition(max > 0)
        return state.withLock { s in
            let dropped = s.dropped
            s.dropped = 0
            if s.entries.count <= max {
                defer { s.entries = [] }
                return (s.entries, dropped)
            }
            let head = Array(s.entries[..<max])
            s.entries.removeFirst(max)
            return (head, dropped)
        }
    }
}
