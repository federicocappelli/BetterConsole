import BCModel
import BCTransport
import Foundation
import Synchronization

/// Streams a physical iOS device's logs from its `com.apple.os_trace_relay` service, over USB
/// when the device is on USB, else over Wi-Fi. A stream whose USB link is lost while the device
/// is still on Wi-Fi continues over Wi-Fi (and the reverse), without ending.
///
/// Each stream runs a dedicated reader thread (the reads block, so they stay off the
/// cooperative pool). Entries are batched like `ProcessLogTransport`: a batch is yielded at
/// 1,000 entries or 50 ms after its first entry. Cancelling the consumer interrupts the
/// blocked read and invalidates the service connection; losing the connection (unplug)
/// makes the stream throw unless another interface takes over.
public struct MobileDeviceLogTransport: LogTransport {
    private let connector: (any OSTraceConnector)?
    private let openRetry: OpenRetryPolicy
    private let link: LinkPolicy

    public init() {
        self.init(connector: MobileDeviceMonitor.shared.map(MobileDeviceConnector.init))
    }

    /// `connector == nil` means MobileDevice is unavailable: nothing is supported.
    init(connector: (any OSTraceConnector)?, openRetry: OpenRetryPolicy = .standard, link: LinkPolicy = .standard) {
        self.connector = connector
        self.openRetry = openRetry
        self.link = link
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
        let session = OSTraceStreamSession(continuation: continuation, openRetry: openRetry, link: link)
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

/// Timings for keeping a stream alive across interfaces (USB to Wi-Fi) and noticing a dead
/// Wi-Fi link.
struct LinkPolicy: Sendable {
    /// After a connection is lost while the device is also on another interface, how long to
    /// wait for the lost interface to be reported gone (the read can fail before the detach
    /// notification arrives). If it is still reported after this, the loss is a plain failure.
    var failoverGrace: Duration
    /// A Wi-Fi connection with no bytes for this long ends once the device is no longer
    /// reported on the network.
    var livenessTimeout: Duration
    var pollInterval: Duration

    static let standard = LinkPolicy(
        failoverGrace: .seconds(2), livenessTimeout: .seconds(10), pollInterval: .milliseconds(100))
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
    /// Connects to the device over `interface` and starts the log relay. Blocks; call off the
    /// cooperative pool. Throws `deviceNotConnected` if the device is not on that interface.
    func open(deviceID: String, over interface: DeviceInterface) throws -> any OSTraceConnection
    /// The interfaces the device is currently reported on (empty when gone).
    func interfaces(of deviceID: String) -> Set<DeviceInterface>
    /// The error to report when opening over `interface` failed for good (after the last
    /// retry); may replace it with a more helpful one. Blocks.
    func explain(_ error: any Error, openingOver interface: DeviceInterface) -> any Error
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
    private let link: LinkPolicy
    /// Signalled by `cancel` to cut a retry backoff or a switch wait short.
    private let wake = DispatchSemaphore(value: 0)

    init(
        continuation: AsyncThrowingStream<[LogEntry], Error>.Continuation, openRetry: OpenRetryPolicy = .standard,
        link: LinkPolicy = .standard
    ) {
        self.continuation = continuation
        self.openRetry = openRetry
        self.link = link
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

    /// The interface a stream opens over: USB whenever the device is on USB, else the network.
    static func preferredInterface(_ interfaces: Set<DeviceInterface>) -> DeviceInterface? {
        if interfaces.contains(.usb) { return .usb }
        if interfaces.contains(.network) { return .network }
        return nil
    }

    private var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Waits up to `interval`, cut short by `cancel`.
    private func pause(_ interval: Duration) {
        let nanoseconds = interval.components.seconds * 1_000_000_000 + interval.components.attoseconds / 1_000_000_000
        _ = wake.wait(timeout: .now() + .nanoseconds(Int(nanoseconds)))
    }

    /// Opens the connection, retrying per `openRetry`. Each attempt picks the interface again
    /// (USB preferred), so a device that moved between attempts is followed. A final Wi-Fi
    /// failure is passed through `connector.explain`. Returns nil if cancelled first.
    private func open(
        connector: any OSTraceConnector, deviceID: String
    ) throws -> (connection: any OSTraceConnection, interface: DeviceInterface)? {
        var attempt = 1
        while true {
            if isCancelled { return nil }
            var interface: DeviceInterface?
            do {
                interface = Self.preferredInterface(connector.interfaces(of: deviceID))
                guard let interface else { throw MobileDeviceError.deviceNotConnected }
                return (try connector.open(deviceID: deviceID, over: interface), interface)
            } catch {
                guard attempt < openRetry.attempts, OpenRetryPolicy.shouldRetry(error) else {
                    // Only a Wi-Fi failure that is final is explained (the connector may check
                    // Local Network access, which is slow and must not stop the retries).
                    if interface == .network, !isCancelled {
                        throw connector.explain(error, openingOver: .network)
                    }
                    throw error
                }
            }
            attempt += 1
            _ = wake.wait(timeout: .now() + openRetry.delay)
        }
    }

    /// The reader thread's body. A connection lost while the device is still reachable on
    /// another interface (USB pulled while on Wi-Fi, or Wi-Fi lost while back on USB) is
    /// reopened over that interface, continuing the same stream; otherwise the loss ends it.
    func run(connector: any OSTraceConnector, deviceID: String) {
        var failure: (any Error)?
        var nextID: UInt64 = 1
        while true {
            let opened: (connection: any OSTraceConnection, interface: DeviceInterface)?
            do {
                opened = try open(connector: connector, deviceID: deviceID)
            } catch {
                failure = error
                break
            }
            guard let (connection, interface) = opened else { break }  // cancelled
            let proceed = state.withLock { state -> Bool in
                guard !state.cancelled else { return false }
                state.connection = connection
                return true
            }
            guard proceed else {
                connection.close()
                break
            }
            let lost = read(connection, interface: interface, connector: connector, deviceID: deviceID, nextID: &nextID)
            // Detach under the lock first, so `cancel` can no longer interrupt it.
            state.withLock { $0.connection = nil }
            connection.close()
            guard let lost else { break }  // cancelled
            guard Self.isLinkLoss(lost), canSwitch(from: interface, connector: connector, deviceID: deviceID) else {
                failure = lost
                break
            }
        }
        finish(failure)
    }

    /// Losses of the link itself (not a refused or corrupt stream), which another interface
    /// may survive.
    static func isLinkLoss(_ error: any Error) -> Bool {
        switch error as? MobileDeviceError {
        case .connectionClosed, .receiveFailed, .networkConnectionLost: true
        default: false
        }
    }

    /// After losing the connection over `lost`: true once `lost` is reported gone while the
    /// device is still on another interface. The read can fail before the detach notification
    /// arrives, so this waits up to `failoverGrace` for it. A device on no other interface
    /// ends at once (a USB-only unplug behaves as before); one still reported on `lost` after
    /// the grace is a plain failure, not a switch.
    private func canSwitch(from lost: DeviceInterface, connector: any OSTraceConnector, deviceID: String) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + link.failoverGrace
        while !isCancelled {
            let interfaces = connector.interfaces(of: deviceID)
            guard Self.preferredInterface(interfaces.subtracting([lost])) != nil else { return false }
            if !interfaces.contains(lost) { return true }
            if clock.now >= deadline { return false }
            pause(link.pollInterval)
        }
        return false
    }

    /// Reads until the connection ends or the stream is cancelled. Returns the error that
    /// ended it (nil after cancellation). A Wi-Fi connection that has had no bytes for
    /// `livenessTimeout` ends once the device is no longer reported on the network.
    private func read(
        _ connection: any OSTraceConnection, interface: DeviceInterface,
        connector: any OSTraceConnector, deviceID: String, nextID: inout UInt64
    ) -> (any Error)? {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.readBufferSize, alignment: 1)
        defer { buffer.deallocate() }
        var status: StatusReplyParser? = StatusReplyParser()
        var decoder = OSTraceDecoder(firstID: nextID)
        defer { nextID = decoder.nextID }
        let clock = ContinuousClock()
        var lastBytes = clock.now
        while true {
            if isCancelled { return nil }
            let result = connection.receive(into: buffer)
            if isCancelled { return nil }
            switch result {
            case .timedOut:
                if interface == .network, clock.now - lastBytes >= link.livenessTimeout,
                   !connector.interfaces(of: deviceID).contains(.network) {
                    return MobileDeviceError.networkConnectionLost
                }
                continue
            case .closed:
                return MobileDeviceError.connectionClosed
            case .failed(let reason):
                return MobileDeviceError.receiveFailed(reason)
            case .bytes(let count):
                lastBytes = clock.now
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
