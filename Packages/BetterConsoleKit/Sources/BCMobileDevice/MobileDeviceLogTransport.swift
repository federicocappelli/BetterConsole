import BCModel
import BCTransport
import Foundation
import Synchronization

/// Streams a physical iOS device's logs from its `com.apple.os_trace_relay` service over USB.
///
/// Each stream runs a dedicated reader thread (the reads block, so they stay off the
/// cooperative pool). Entries are batched like `ProcessLogTransport`: a batch is yielded at
/// 1,000 entries or 50 ms after its first entry. Cancelling the consumer interrupts the
/// blocked read and invalidates the service connection; losing the connection (unplug)
/// makes the stream throw.
public struct MobileDeviceLogTransport: LogTransport {
    private let connector: (any OSTraceConnector)?
    private let openRetry: OpenRetryPolicy

    public init() {
        self.init(connector: MobileDeviceMonitor.shared.map(MobileDeviceConnector.init))
    }

    /// `connector == nil` means MobileDevice is unavailable: nothing is supported.
    init(connector: (any OSTraceConnector)?, openRetry: OpenRetryPolicy = .standard) {
        self.connector = connector
        self.openRetry = openRetry
    }

    public func supports(_ device: LogDevice) -> Bool {
        connector != nil && device.kind == .physical
    }

    public func stream(from device: LogDevice) -> AsyncThrowingStream<[LogEntry], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [LogEntry].self, throwing: Error.self)
        guard let connector else {
            continuation.finish(throwing: MobileDeviceError.frameworkUnavailable)
            return stream
        }
        let session = OSTraceStreamSession(continuation: continuation, openRetry: openRetry)
        continuation.onTermination = { termination in
            // `.finished` is delivered from inside `continuation.finish`, which the session
            // calls while holding its lock: only `.cancelled` may call back into it.
            if case .cancelled = termination { session.cancel() }
        }
        let reader = Thread { session.run(connector: connector, deviceID: device.id) }
        reader.name = "BCMobileDevice.reader.\(device.id)"
        reader.qualityOfService = .userInitiated
        reader.start()
        return stream
    }
}

/// How often to retry opening the relay. Right after plug-in (a replug triggers auto-resume
/// at once) lockdown may not answer yet, so a failed open is retried while the device stays
/// attached. Not retried: not connected (gone) and not paired (needs the user).
struct OpenRetryPolicy: Sendable {
    var attempts: Int
    var delay: DispatchTimeInterval

    static let standard = OpenRetryPolicy(attempts: 5, delay: .seconds(1))

    static func shouldRetry(_ error: any Error) -> Bool {
        switch error as? MobileDeviceError {
        case .deviceNotConnected, .notPaired, .frameworkUnavailable: false
        default: true
        }
    }
}

// MARK: - Connection abstraction (swappable transport; faked in tests)

enum ReceiveResult: Sendable, Equatable {
    case bytes(Int)
    /// Nothing arrived within the read timeout; the connection is still usable.
    case timedOut
    /// The peer closed the connection (or `interrupt` shut it down).
    case closed
    case failed(String)
}

/// An open `os_trace_relay` service connection with the `StartActivity` request already sent.
///
/// Threading contract: `receive` and `close` are called only from the stream's reader thread,
/// and `close` exactly once. `interrupt` may be called from any thread while the connection
/// is open; the caller guarantees (with its own lock) that it never runs during or after
/// `close`.
protocol OSTraceConnection: AnyObject, Sendable {
    /// Blocks until bytes arrive, the read timeout passes, or the connection ends.
    func receive(into buffer: UnsafeMutableRawBufferPointer) -> ReceiveResult
    /// Wakes a blocked `receive` promptly and makes later ones return `.closed`.
    func interrupt()
    /// Invalidates the connection and releases the device.
    func close()
}

protocol OSTraceConnector: Sendable {
    /// Connects to the device and starts the log relay. Blocks; call off the cooperative pool.
    func open(deviceID: String) throws -> any OSTraceConnection
}

// MARK: - Status reply

/// Parses the one-off reply to `StartActivity`, which is NOT in the usual 4-byte big-endian
/// plist-message framing: u32 little-endian N, then an N-byte little-endian length, then a
/// binary plist `{Status: "RequestSuccessful"}`. Bytes after it are entry frames.
struct StatusReplyParser {
    enum Outcome: Equatable {
        case needMore
        case done(remainder: Data)
    }

    static let maximumReplyLength = 64 * 1024
    private var buffer = Data()

    mutating func feed(_ bytes: Data) throws -> Outcome {
        buffer.append(bytes)
        let b = [UInt8](buffer.prefix(12))
        guard b.count >= 4 else { return .needMore }
        let lengthBytes = Int(OSTraceDecoder.u32(b, 0))
        guard (1...8).contains(lengthBytes) else {
            throw MobileDeviceError.badStatusReply("invalid length prefix \(lengthBytes)")
        }
        guard b.count >= 4 + lengthBytes else { return .needMore }
        var length: UInt64 = 0
        for i in 0..<lengthBytes { length |= UInt64(b[4 + i]) << (8 * UInt64(i)) }
        guard length <= UInt64(Self.maximumReplyLength) else {
            throw MobileDeviceError.badStatusReply("reply length \(length)")
        }
        let plistStart = 4 + lengthBytes
        let plistEnd = plistStart + Int(length)
        guard buffer.count >= plistEnd else { return .needMore }
        let bytes = Data(buffer[(buffer.startIndex + plistStart)..<(buffer.startIndex + plistEnd)])
        let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil)
        guard let status = (plist as? [String: Any])?["Status"] as? String else {
            throw MobileDeviceError.badStatusReply("unreadable reply")
        }
        guard status == "RequestSuccessful" else { throw MobileDeviceError.badStatusReply(status) }
        let remainder = Data(buffer[(buffer.startIndex + plistEnd)...])
        buffer = Data()
        return .done(remainder: remainder)
    }
}

// MARK: - Stream session

/// One stream: the reader thread's loop plus batching. Batches are yielded while holding the
/// lock so they reach the continuation in order; the 50 ms timer and cancellation also go
/// through the lock.
final class OSTraceStreamSession: Sendable {
    static let maxBatchSize = 1_000
    static let maxBatchDelay: DispatchTimeInterval = .milliseconds(50)
    static let readBufferSize = 64 * 1024

    private struct State {
        var connection: (any OSTraceConnection)?
        var cancelled = false
        var finished = false
        var pending: [LogEntry] = []
        var timerArmed = false
        var timerGeneration = 0
    }

    private let continuation: AsyncThrowingStream<[LogEntry], Error>.Continuation
    private let state = Mutex(State())
    private let openRetry: OpenRetryPolicy
    /// Signalled by `cancel` to cut a retry backoff short.
    private let wake = DispatchSemaphore(value: 0)

    init(continuation: AsyncThrowingStream<[LogEntry], Error>.Continuation, openRetry: OpenRetryPolicy = .standard) {
        self.continuation = continuation
        self.openRetry = openRetry
    }

    /// Called from `onTermination(.cancelled)`. Interrupts a blocked read; the reader thread
    /// then closes the connection and finishes.
    func cancel() {
        state.withLock { state in
            state.cancelled = true
            state.connection?.interrupt()
        }
        wake.signal()
    }

    /// Opens the connection, retrying per `openRetry`. Returns nil if cancelled first.
    private func open(connector: any OSTraceConnector, deviceID: String) throws -> (any OSTraceConnection)? {
        var attempt = 1
        while true {
            if state.withLock({ $0.cancelled }) { return nil }
            do {
                return try connector.open(deviceID: deviceID)
            } catch {
                guard attempt < openRetry.attempts, OpenRetryPolicy.shouldRetry(error) else { throw error }
            }
            attempt += 1
            _ = wake.wait(timeout: .now() + openRetry.delay)
        }
    }

    /// The reader thread's body.
    func run(connector: any OSTraceConnector, deviceID: String) {
        let failure: (any Error)?
        do {
            guard let connection = try open(connector: connector, deviceID: deviceID) else {
                finish(nil)
                return
            }
            let proceed = state.withLock { state -> Bool in
                guard !state.cancelled else { return false }
                state.connection = connection
                return true
            }
            if proceed {
                failure = read(connection)
                // Detach under the lock first, so `cancel` can no longer interrupt it.
                state.withLock { $0.connection = nil }
            } else {
                failure = nil
            }
            connection.close()
        } catch {
            failure = error
        }
        finish(failure)
    }

    /// Reads until the connection ends or the stream is cancelled. Returns the error that
    /// ended it (nil after cancellation).
    private func read(_ connection: any OSTraceConnection) -> (any Error)? {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.readBufferSize, alignment: 1)
        defer { buffer.deallocate() }
        var status: StatusReplyParser? = StatusReplyParser()
        var decoder = OSTraceDecoder()
        while true {
            if state.withLock({ $0.cancelled }) { return nil }
            let result = connection.receive(into: buffer)
            if state.withLock({ $0.cancelled }) { return nil }
            switch result {
            case .timedOut:
                continue
            case .closed:
                return MobileDeviceError.connectionClosed
            case .failed(let reason):
                return MobileDeviceError.receiveFailed(reason)
            case .bytes(let count):
                var bytes = Data(bytes: buffer.baseAddress!, count: count)
                if var parser = status {
                    do {
                        switch try parser.feed(bytes) {
                        case .needMore:
                            status = parser
                            continue
                        case .done(let remainder):
                            status = nil
                            bytes = remainder
                        }
                    } catch {
                        return error
                    }
                }
                let entries = decoder.feed(bytes)
                deliver(entries)
                if let error = decoder.error { return error }
            }
        }
    }

    // MARK: Batching

    private func deliver(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        state.withLock { state in
            guard !state.finished else { return }
            for entry in entries {
                state.pending.append(entry)
                if state.pending.count >= Self.maxBatchSize { flush(&state) }
            }
            armTimerIfNeeded(&state)
        }
    }

    private func armTimerIfNeeded(_ state: inout State) {
        guard !state.pending.isEmpty, !state.timerArmed else { return }
        state.timerArmed = true
        let generation = state.timerGeneration
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.maxBatchDelay) { [weak self] in
            self?.state.withLock { state in
                guard state.timerArmed, state.timerGeneration == generation, !state.finished else { return }
                self?.flush(&state)
            }
        }
    }

    private func flush(_ state: inout State) {
        state.timerArmed = false
        state.timerGeneration &+= 1
        guard !state.pending.isEmpty else { return }
        continuation.yield(state.pending)
        state.pending.removeAll(keepingCapacity: true)
    }

    private func finish(_ failure: (any Error)?) {
        state.withLock { state in
            guard !state.finished else { return }
            flush(&state)
            state.finished = true
            if state.cancelled || failure == nil {
                continuation.finish()
            } else {
                continuation.finish(throwing: failure!)
            }
        }
    }
}
