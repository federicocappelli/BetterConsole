import Synchronization
import BCFilter

/// A session's current compiled filter, shared with its off-main checker (spec §8.2). The
/// generation bumps on every change, so the drain can tell verdicts computed against an older
/// filter from current ones. `nil` means no filter.
final class FilterSlot: Sendable {
    private let state = Mutex<(generation: UInt64, filter: CompiledFilter?)>((0, nil))

    func current() -> (UInt64, CompiledFilter?) {
        state.withLock { ($0.generation, $0.filter) }
    }

    /// Installs `filter` and returns its new generation.
    @discardableResult
    func set(_ filter: CompiledFilter?) -> UInt64 {
        state.withLock {
            $0.generation += 1
            $0.filter = filter
            return $0.generation
        }
    }
}
