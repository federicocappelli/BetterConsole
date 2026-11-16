import Foundation
import BCModel

/// A source of log entries for a device (spec §6.4).
public protocol LogTransport: Sendable {
    func supports(_ device: LogDevice) -> Bool
    /// Starts streaming. Entries arrive in batches. Cancelling the consuming task
    /// (or dropping the stream) stops the underlying source.
    ///
    /// The stream buffers without limit (it never drops, since the spec requires every
    /// drop to be counted and shown, and this protocol has no channel to report one).
    /// Contract for consumers: drain continuously, off the main actor, with no awaits
    /// between `next()` calls other than the iteration itself. Overload is absorbed and
    /// counted downstream, in the consumer's bounded queue (Task 6), not here.
    func stream(from device: LogDevice) -> AsyncThrowingStream<[LogEntry], Error>

    /// A finite source (a file): its stream ends normally once everything is read, and no
    /// entry may be lost, so the consumer waits for room instead of dropping. Its stream should
    /// produce batches as they are asked for, so waiting holds the source back.
    var isFinite: Bool { get }
}

extension LogTransport {
    public var isFinite: Bool { false }
}

public enum TransportError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The source stopped on its own (not because the consumer cancelled).
    /// For a child process: its exit code, or 128 + signal number if it was killed by a signal.
    case processExited(status: Int32)
    case launchFailed(String)

    /// A plain sentence; the session banner shows it as is.
    public var description: String {
        switch self {
        case .processExited(let status):
            "The log process exited unexpectedly (status \(status))."
        case .launchFailed(let detail):
            "Couldn't start the log process: \(detail)."
        }
    }

    public var errorDescription: String? { description }
}
