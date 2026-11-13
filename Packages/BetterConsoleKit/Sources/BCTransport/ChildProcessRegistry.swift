import Foundation
import Synchronization

/// Every live child spawned by `ProcessLogTransport`, so the app can kill them all at quit.
public final class ChildProcessRegistry: Sendable {
    public static let shared = ChildProcessRegistry()

    private let children = Mutex<[pid_t: ProcessSession]>([:])

    init() {}

    /// Pids (= process group ids) of the live children.
    public var pids: [pid_t] {
        children.withLock { Array($0.keys) }
    }

    func register(_ session: ProcessSession) {
        children.withLock { $0[session.pid] = session }
    }

    func unregister(_ pid: pid_t) {
        _ = children.withLock { $0.removeValue(forKey: pid) }
    }

    /// Sends SIGTERM to every child's process group, waits up to `grace` for them to
    /// exit, then SIGKILLs the groups still alive. Blocks the caller for at most `grace`;
    /// meant for app termination, where the process is about to exit anyway.
    /// Streams ended this way finish without an error, as if cancelled.
    public func terminateAll(grace: Duration = .seconds(1)) {
        // Snapshot, then call out without holding our lock: sessions call `unregister`.
        let sessions = children.withLock { Array($0.values) }
        guard !sessions.isEmpty else { return }
        for session in sessions { session.terminate() }

        let clock = ContinuousClock()
        let deadline = clock.now + grace
        while clock.now < deadline, sessions.contains(where: { !$0.isLeaderGone }) {
            usleep(5_000)
        }
        for session in sessions { session.forceKill() }
    }
}
