import BCModel
import BCTransport
import Foundation
import Network
import Synchronization
import Testing
@testable import BCMobileDevice

// MARK: - Fakes

/// A scripted service connection. `receive` pops steps in order; when the script runs out it
/// blocks like a socket with no data until `interrupt()` (as `shutdown` would), then reports
/// the connection closed. With `silentWhenDone` it instead keeps timing out (a live but quiet
/// link). `.action` runs its closure (e.g. a device event) and moves on to the next step.
final class FakeConnection: OSTraceConnection {
    enum Step: Sendable { case data(Data), timedOut, closed, failed(String), action(@Sendable () -> Void) }

    private struct State {
        var script: [Step]
        var interrupted = false
        var closeCount = 0
        var receiveCount = 0
    }
    private let state: Mutex<State>
    private let wake = DispatchSemaphore(value: 0)
    private let silentWhenDone: Bool

    init(_ script: [Step], silentWhenDone: Bool = false) {
        state = Mutex(State(script: script))
        self.silentWhenDone = silentWhenDone
    }

    func receive(into buffer: UnsafeMutableRawBufferPointer) -> ReceiveResult {
        while true {
            let step: Step? = state.withLock { state in
                state.receiveCount += 1
                guard !state.interrupted, !state.script.isEmpty else { return nil }
                let step = state.script.removeFirst()
                if case .data(let data) = step, data.count > buffer.count {
                    state.script.insert(.data(data.dropFirst(buffer.count)), at: 0)
                    return .data(data.prefix(buffer.count))
                }
                return step
            }
            switch step {
            case .data(let data):
                data.copyBytes(to: buffer.bindMemory(to: UInt8.self), count: data.count)
                return .bytes(data.count)
            case .timedOut: return .timedOut
            case .closed: return .closed
            case .failed(let reason): return .failed(reason)
            case .action(let action):
                action()
                continue
            case nil:
                if silentWhenDone, !interrupted {
                    _ = wake.wait(timeout: .now() + .milliseconds(10))
                    if !interrupted { return .timedOut }
                    return .closed
                }
                _ = wake.wait(timeout: .now() + 10)
                return .closed
            }
        }
    }

    func interrupt() {
        state.withLock { $0.interrupted = true }
        wake.signal()
    }

    func close() { state.withLock { $0.closeCount += 1 } }

    var interrupted: Bool { state.withLock { $0.interrupted } }
    var closeCount: Int { state.withLock { $0.closeCount } }
    var receiveCount: Int { state.withLock { $0.receiveCount } }
}

/// Hands out `connections` in order (the last one again once they run out) and reports the
/// device on `interfaces`, which tests change to model plug, unplug and Wi-Fi coming and going.
/// Opening over an interface the device is not on throws `deviceNotConnected`, like the real
/// connector.
final class FakeConnector: OSTraceConnector {
    private struct State {
        var connections: [FakeConnection]
        var interfaces: Set<DeviceInterface>
        var opened: [(id: String, interface: DeviceInterface)] = []
    }
    private let state: Mutex<State>
    private let openError: (any Error)?
    private let openErrors: [DeviceInterface: any Error]
    private let explanation: (@Sendable (any Error, DeviceInterface) -> any Error)?
    private let explained = Mutex<[DeviceInterface]>([])
    private let openGate: DispatchSemaphore?
    /// The first `transientFailures` opens throw a retryable error (lockdown not ready yet).
    private let transientFailures: Int

    convenience init(_ connection: FakeConnection?, openError: (any Error)? = nil, openGate: DispatchSemaphore? = nil,
         transientFailures: Int = 0) {
        self.init(connections: connection.map { [$0] } ?? [], interfaces: [.usb], openError: openError,
                  openGate: openGate, transientFailures: transientFailures)
    }

    init(connections: [FakeConnection], interfaces: Set<DeviceInterface>, openError: (any Error)? = nil,
         openErrors: [DeviceInterface: any Error] = [:], openGate: DispatchSemaphore? = nil,
         transientFailures: Int = 0, explanation: (@Sendable (any Error, DeviceInterface) -> any Error)? = nil) {
        state = Mutex(State(connections: connections, interfaces: interfaces))
        self.openError = openError
        self.openErrors = openErrors
        self.explanation = explanation
        self.openGate = openGate
        self.transientFailures = transientFailures
    }

    static let transientError = MobileDeviceError.callFailed(function: "AMDeviceStartSession", code: -402653158, text: nil)

    func open(deviceID: String, over interface: DeviceInterface) throws -> any OSTraceConnection {
        let (attempt, reported) = state.withLock { state in
            state.opened.append((deviceID, interface))
            return (state.opened.count, state.interfaces.contains(interface))
        }
        openGate?.wait()
        if attempt <= transientFailures { throw Self.transientError }
        if let openError { throw openError }
        guard reported else { throw MobileDeviceError.deviceNotConnected }
        if let error = openErrors[interface] { throw error }
        return state.withLock { state in
            state.connections.count > 1 ? state.connections.removeFirst() : state.connections[0]
        }
    }

    func interfaces(of deviceID: String) -> Set<DeviceInterface> { state.withLock { $0.interfaces } }

    func explain(_ error: any Error, openingOver interface: DeviceInterface) -> any Error {
        explained.withLock { $0.append(interface) }
        return explanation?(error, interface) ?? error
    }

    /// Interfaces of the failed opens `explain` was asked about.
    var explainedInterfaces: [DeviceInterface] { explained.withLock { $0 } }

    func setInterfaces(_ interfaces: Set<DeviceInterface>) { state.withLock { $0.interfaces = interfaces } }

    var openedIDs: [String] { state.withLock { $0.opened.map(\.id) } }
    var openedInterfaces: [DeviceInterface] { state.withLock { $0.opened.map(\.interface) } }
}

// MARK: - Helpers

let phone = LogDevice(id: "00000000-0000000000000000", name: "Test iPhone", kind: .physical)

/// The status reply as the device sends it: u32 length-of-length, the length, the plist.
func statusReply(_ status: String = "RequestSuccessful", lengthBytes: Int = 1) throws -> Data {
    let plist = try PropertyListSerialization.data(
        fromPropertyList: ["Status": status], format: .binary, options: 0)
    var data = Data([UInt8(lengthBytes), 0, 0, 0])
    for i in 0..<lengthBytes { data.append(UInt8(truncatingIfNeeded: plist.count >> (8 * i))) }
    return data + plist
}

func streamFixture() throws -> Data { try OSTraceDecoderTests.fixture("ostrace-stream") }

struct Outcome {
    var batches: [[LogEntry]] = []
    var error: (any Error)?
    var entries: [LogEntry] { batches.flatMap { $0 } }
}

func collect(_ stream: AsyncThrowingStream<[LogEntry], Error>) async -> Outcome {
    var outcome = Outcome()
    do {
        for try await batch in stream { outcome.batches.append(batch) }
    } catch {
        outcome.error = error
    }
    return outcome
}

/// Polls `condition` until true or `timeout` passes.
func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: - Status reply

struct StatusReplyParserTests {
    @Test func parsesReplyAndReturnsTrailingFrameBytes() throws {
        var parser = StatusReplyParser()
        let frames = try streamFixture()
        let outcome = try parser.feed(try statusReply() + frames)
        #expect(outcome == .done(remainder: frames))
    }

    @Test func parsesReplySplitByteByByte() throws {
        var parser = StatusReplyParser()
        let reply = try statusReply(lengthBytes: 2)
        for byte in reply.dropLast() {
            #expect(try parser.feed(Data([byte])) == .needMore)
        }
        #expect(try parser.feed(Data([reply.last!])) == .done(remainder: Data()))
    }

    @Test func rejectsFailureStatus() throws {
        var parser = StatusReplyParser()
        #expect(throws: MobileDeviceError.badStatusReply("RequestFailed")) {
            try parser.feed(try statusReply("RequestFailed"))
        }
    }

    @Test func rejectsInsaneLengthOfLength() {
        var parser = StatusReplyParser()
        #expect(throws: MobileDeviceError.self) {
            try parser.feed(Data([0x00, 0x00, 0x00, 0x01]))
        }
    }

    @Test func rejectsUnparseablePlist() {
        var parser = StatusReplyParser()
        #expect(throws: MobileDeviceError.self) {
            try parser.feed(Data([1, 0, 0, 0, 3, 0x41, 0x42, 0x43]))
        }
    }
}

// MARK: - Transport

@Suite struct MobileDeviceLogTransportTests {
    @Test func supportsOnlyPhysicalDevices() {
        let transport = MobileDeviceLogTransport(connector: FakeConnector(nil))
        #expect(transport.supports(phone))
        #expect(!transport.supports(LogDevice(id: "local", name: "Mac", kind: .thisMac)))
        #expect(!transport.supports(LogDevice(id: "sim", name: "Sim", kind: .simulator)))
    }

    @Test func unavailableFrameworkSupportsNothing() async {
        let transport = MobileDeviceLogTransport(connector: nil)
        #expect(!transport.supports(phone))
        let outcome = await collect(transport.stream(from: phone))
        #expect(outcome.error as? MobileDeviceError == .frameworkUnavailable)
    }

    /// Unplug: the read fails (or hits EOF) and the stream throws, after delivering every
    /// entry decoded before the loss.
    @Test(arguments: [FakeConnection.Step.closed, .failed("Device not configured")])
    func connectionLossThrowsAfterDeliveringEntries(_ loss: FakeConnection.Step) async throws {
        let frames = try streamFixture()
        let connection = FakeConnection([
            .data(try statusReply() + frames.prefix(1000)),
            .timedOut,
            .data(frames.dropFirst(1000)),
            loss,
        ])
        let connector = FakeConnector(connection)
        let outcome = await collect(MobileDeviceLogTransport(connector: connector).stream(from: phone))
        #expect(connector.openedIDs == [phone.id])
        #expect(outcome.entries.count == 50)
        #expect(outcome.entries.map(\.id) == Array(1...50))
        switch loss {
        case .closed: #expect(outcome.error as? MobileDeviceError == .connectionClosed)
        default: #expect(outcome.error as? MobileDeviceError == .receiveFailed("Device not configured"))
        }
        #expect(connection.closeCount == 1)
    }

    @Test func failedStatusReplyThrows() async throws {
        let connection = FakeConnection([.data(try statusReply("RequestFailed"))])
        let outcome = await collect(MobileDeviceLogTransport(connector: FakeConnector(connection)).stream(from: phone))
        #expect(outcome.entries.isEmpty)
        #expect(outcome.error as? MobileDeviceError == .badStatusReply("RequestFailed"))
        #expect(connection.closeCount == 1)
    }

    @Test func openFailureThrows() async {
        let connector = FakeConnector(nil, openError: MobileDeviceError.notPaired)
        let outcome = await collect(MobileDeviceLogTransport(connector: connector).stream(from: phone))
        #expect(outcome.error as? MobileDeviceError == .notPaired)
    }

    // MARK: Open retry (replug: lockdown may not answer right after plug-in)

    static let fastRetry = OpenRetryPolicy(attempts: 5, delay: .milliseconds(20))

    @Test func openFailsTwiceThenOpens() async throws {
        let connection = FakeConnection([.data(try statusReply() + (try streamFixture())), .closed])
        let connector = FakeConnector(connection, transientFailures: 2)
        let transport = MobileDeviceLogTransport(connector: connector, openRetry: Self.fastRetry)
        let outcome = await collect(transport.stream(from: phone))
        #expect(connector.openedIDs.count == 3)
        #expect(outcome.entries.count == 50)
        #expect(outcome.error as? MobileDeviceError == .connectionClosed)
    }

    @Test func openGivesUpAfterLastAttempt() async {
        let connector = FakeConnector(nil, transientFailures: 100)
        let transport = MobileDeviceLogTransport(
            connector: connector, openRetry: OpenRetryPolicy(attempts: 3, delay: .milliseconds(10)))
        let outcome = await collect(transport.stream(from: phone))
        #expect(connector.openedIDs.count == 3)
        #expect(outcome.error as? MobileDeviceError == FakeConnector.transientError)
    }

    @Test(arguments: [MobileDeviceError.notPaired, .deviceNotConnected])
    func openIsNotRetriedWhenUnpairedOrGone(_ error: MobileDeviceError) async {
        let connector = FakeConnector(nil, openError: error)
        let transport = MobileDeviceLogTransport(connector: connector, openRetry: Self.fastRetry)
        let outcome = await collect(transport.stream(from: phone))
        #expect(connector.openedIDs.count == 1)
        #expect(outcome.error as? MobileDeviceError == error)
    }

    @Test func cancelDuringRetryBackoffStopsPromptly() async throws {
        let connector = FakeConnector(nil, transientFailures: 100)
        let transport = MobileDeviceLogTransport(
            connector: connector, openRetry: OpenRetryPolicy(attempts: 5, delay: .seconds(10)))
        let stream = transport.stream(from: phone)
        let consumer = Task { for try await _ in stream {} }
        #expect(await eventually { connector.openedIDs.count == 1 })
        try await Task.sleep(for: .milliseconds(20))  // now inside the 10 s backoff
        let cancelledAt = ContinuousClock.now
        consumer.cancel()
        let result = await consumer.result
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
        if case .failure(let error) = result { Issue.record("cancelled stream threw \(error)") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(connector.openedIDs.count == 1)  // no further attempt after cancel
    }

    @Test func corruptStreamFailsCleanly() async throws {
        let frames = try streamFixture()
        let connection = FakeConnection([
            .data(try statusReply() + frames + Data([0x02, 0xff, 0xff, 0xff, 0xff])),
        ])
        let outcome = await collect(MobileDeviceLogTransport(connector: FakeConnector(connection)).stream(from: phone))
        #expect(outcome.entries.count == 50)
        #expect(outcome.error as? OSTraceDecoder.DecodeError == .frameTooLarge(0xffff_ffff))
        #expect(connection.closeCount == 1)
    }

    @Test func batchesHoldAtMostOneThousandEntries() async throws {
        let frames = try streamFixture()
        let many = Data((0..<50).map { _ in frames }.joined())  // 2,500 entries
        let connection = FakeConnection([.data(try statusReply() + many), .closed])
        let outcome = await collect(MobileDeviceLogTransport(connector: FakeConnector(connection)).stream(from: phone))
        #expect(outcome.entries.count == 2_500)
        #expect(outcome.batches.allSatisfy { $0.count <= 1_000 })
        #expect(outcome.batches.first?.count == 1_000)
    }

    /// A partial batch is delivered by the 50 ms timer while the connection stays open.
    @Test func partialBatchFlushesWithoutMoreData() async throws {
        let connection = FakeConnection([.data(try statusReply() + (try streamFixture()))])
        let stream = MobileDeviceLogTransport(connector: FakeConnector(connection)).stream(from: phone)
        var iterator = stream.makeAsyncIterator()
        let started = ContinuousClock.now
        let batch = try await iterator.next()
        #expect(batch?.count == 50)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(!connection.interrupted)
        _ = iterator  // dropping the iterator terminates the stream
    }

    /// Cancelling the consumer interrupts the blocked read promptly, closes the connection
    /// once, and ends the stream without an error.
    @Test func cancellationInterruptsBlockedReadAndClosesConnection() async throws {
        let connection = FakeConnection([.data(try statusReply() + (try streamFixture()))])
        let stream = MobileDeviceLogTransport(connector: FakeConnector(connection)).stream(from: phone)
        let received = Mutex(0)
        let consumer = Task {
            for try await batch in stream { received.withLock { $0 += batch.count } }
        }
        #expect(await eventually { received.withLock { $0 } == 50 })
        let cancelledAt = ContinuousClock.now
        consumer.cancel()
        #expect(await eventually { connection.closeCount == 1 })
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
        #expect(connection.interrupted)
        let result = await consumer.result
        if case .failure(let error) = result { Issue.record("cancelled stream threw \(error)") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.closeCount == 1)
    }

    /// Cancelled while the (blocking) connect is still running: the connection that eventually
    /// opens is closed at once and never read.
    @Test func cancellationDuringOpenClosesTheLateConnection() async throws {
        let gate = DispatchSemaphore(value: 0)
        let connection = FakeConnection([.data(try statusReply() + (try streamFixture()))])
        let connector = FakeConnector(connection, openGate: gate)
        let stream = MobileDeviceLogTransport(connector: connector).stream(from: phone)
        let consumer = Task { for try await _ in stream {} }
        #expect(await eventually { connector.openedIDs.count == 1 })
        consumer.cancel()
        _ = await consumer.result
        gate.signal()
        #expect(await eventually { connection.closeCount == 1 })
        #expect(connection.receiveCount == 0)
    }

    /// Simulated unplug then replug: the first stream throws on connection loss; a new
    /// stream (what the session starts when the device returns) streams again from id 1.
    @Test func newStreamAfterDisconnectStreamsAgain() async throws {
        let frames = try streamFixture()
        let first = FakeConnection([.data(try statusReply() + frames), .failed("Device not configured")])
        let firstOutcome = await collect(MobileDeviceLogTransport(connector: FakeConnector(first)).stream(from: phone))
        #expect(firstOutcome.error != nil)
        #expect(firstOutcome.entries.count == 50)

        let second = FakeConnection([.data(try statusReply() + frames), .closed])
        let secondOutcome = await collect(MobileDeviceLogTransport(connector: FakeConnector(second)).stream(from: phone))
        #expect(secondOutcome.entries.map(\.id) == Array(1...50))
    }
}

// MARK: - Wi-Fi: interface choice, USB to Wi-Fi switch, liveness

@Suite struct WirelessTransportTests {
    static let fastRetry = OpenRetryPolicy(attempts: 5, delay: .milliseconds(20))
    static let fastLink = LinkPolicy(
        failoverGrace: .milliseconds(500), livenessTimeout: .milliseconds(200), pollInterval: .milliseconds(10))

    func transport(_ connector: FakeConnector, link: LinkPolicy = Self.fastLink) -> MobileDeviceLogTransport {
        MobileDeviceLogTransport(connector: connector, openRetry: Self.fastRetry, link: link)
    }

    @Test func startsOverUSBWhenTheDeviceIsOnBoth() async throws {
        let connection = FakeConnection([.data(try statusReply() + (try streamFixture())), .closed])
        // USB stays reported, so the stream's end is a plain failure, not a switch.
        let connector = FakeConnector(connections: [connection], interfaces: [.usb, .network])
        let outcome = await collect(transport(connector).stream(from: phone))
        #expect(connector.openedInterfaces == [.usb])
        #expect(outcome.entries.count == 50)
    }

    @Test func startsOverWifiWhenTheDeviceIsOnlyOnTheNetwork() async throws {
        let connection = FakeConnection([.data(try statusReply() + (try streamFixture())), .closed])
        let connector = FakeConnector(connections: [connection], interfaces: [.network])
        let outcome = await collect(transport(connector).stream(from: phone))
        #expect(connector.openedInterfaces == [.network])
        #expect(outcome.entries.count == 50)
        #expect(outcome.error as? MobileDeviceError == .connectionClosed)
    }

    @Test func picksTheInterfaceAgainOnEachOpenAttempt() async throws {
        let connection = FakeConnection([.data(try statusReply() + (try streamFixture())), .closed])
        let connector = FakeConnector(connections: [connection], interfaces: [.usb], transientFailures: 1)
        // The first (USB) attempt fails; by the second the cable is out and Wi-Fi is up.
        let link = LinkPolicy(failoverGrace: .milliseconds(500), livenessTimeout: .seconds(10), pollInterval: .milliseconds(10))
        let slowRetry = OpenRetryPolicy(attempts: 5, delay: .milliseconds(200))
        let stream = MobileDeviceLogTransport(connector: connector, openRetry: slowRetry, link: link).stream(from: phone)
        #expect(await eventually { connector.openedIDs.count == 1 })
        connector.setInterfaces([.network])
        let outcome = await collect(stream)
        #expect(connector.openedInterfaces == [.usb, .network])
        #expect(outcome.entries.count == 50)
    }

    /// The cable is pulled mid-stream while the device is on Wi-Fi: the stream reopens over
    /// Wi-Fi and keeps going in the same stream, without an error, with ids continuing.
    @Test func usbLossSwitchesToWifiWithoutEndingTheStream() async throws {
        let frames = try streamFixture()
        let holder = Mutex<FakeConnector?>(nil)
        // The detach is delivered just before the read fails.
        let usb = FakeConnection([
            .data(try statusReply() + frames),
            .action { holder.withLock { $0?.setInterfaces([.network]) } },
            .failed("Device not configured"),
        ])
        let wifi = FakeConnection([
            .data(try statusReply() + frames),
            .action { holder.withLock { $0?.setInterfaces([]) } },
            .closed,
        ])
        let connector = FakeConnector(connections: [usb, wifi], interfaces: [.usb, .network])
        holder.withLock { $0 = connector }
        let outcome = await collect(transport(connector).stream(from: phone))
        #expect(connector.openedInterfaces == [.usb, .network])
        #expect(outcome.entries.count == 100)
        #expect(outcome.entries.map(\.id) == Array(1...100))
        // Only the Wi-Fi connection's own end (with nowhere left to go) ends the stream.
        #expect(outcome.error as? MobileDeviceError == .connectionClosed)
        #expect(usb.closeCount == 1)
        #expect(wifi.closeCount == 1)
    }

    /// The read fails before the detach notification arrives: the stream waits for USB to
    /// go, then switches.
    @Test func usbLossBeforeTheDetachWaitsForItThenSwitches() async throws {
        let frames = try streamFixture()
        let holder = Mutex<FakeConnector?>(nil)
        let usb = FakeConnection([
            .data(try statusReply() + frames),
            .action {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
                    holder.withLock { $0?.setInterfaces([.network]) }
                }
            },
            .closed,
        ])
        let wifi = FakeConnection([.data(try statusReply() + frames), .closed])
        let connector = FakeConnector(connections: [usb, wifi], interfaces: [.usb, .network])
        holder.withLock { $0 = connector }
        let outcome = await collect(transport(connector).stream(from: phone))
        #expect(connector.openedInterfaces == [.usb, .network])
        #expect(outcome.entries.count == 100)
    }

    /// A USB read failure while the device is still on USB is not a switch: the stream ends
    /// with the failure, as before Wi-Fi support.
    @Test func usbFailureWhileStillOnUSBEndsTheStream() async throws {
        let usb = FakeConnection([.data(try statusReply() + (try streamFixture())), .failed("boom")])
        let connector = FakeConnector(connections: [usb], interfaces: [.usb, .network])
        let outcome = await collect(transport(connector).stream(from: phone))
        #expect(connector.openedInterfaces == [.usb])
        #expect(outcome.error as? MobileDeviceError == .receiveFailed("boom"))
    }

    /// USB-only device unplugged: ends at once, without waiting out the switch grace.
    @Test func usbOnlyUnplugEndsAtOnce() async throws {
        let holder = Mutex<FakeConnector?>(nil)
        let usb = FakeConnection([
            .data(try statusReply() + (try streamFixture())),
            .action { holder.withLock { $0?.setInterfaces([]) } },
            .failed("Device not configured"),
        ])
        let connector = FakeConnector(connections: [usb], interfaces: [.usb])
        holder.withLock { $0 = connector }
        let started = ContinuousClock.now
        let link = LinkPolicy(failoverGrace: .seconds(5), livenessTimeout: .seconds(10), pollInterval: .milliseconds(10))
        let outcome = await collect(transport(connector, link: link).stream(from: phone))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(connector.openedInterfaces == [.usb])
        #expect(outcome.error as? MobileDeviceError == .receiveFailed("Device not configured"))
    }

    /// The switch fails (e.g. Local Network access off): the Wi-Fi open is retried as usual,
    /// then the stream fails with the connector's explanation of the last failure.
    @Test func failedSwitchFailsTheStreamWithItsReason() async throws {
        let holder = Mutex<FakeConnector?>(nil)
        let usb = FakeConnection([
            .data(try statusReply() + (try streamFixture())),
            .action { holder.withLock { $0?.setInterfaces([.network]) } },
            .closed,
        ])
        let connector = FakeConnector(
            connections: [usb], interfaces: [.usb, .network], openErrors: [.network: FakeConnector.transientError],
            explanation: { _, _ in MobileDeviceError.localNetworkDenied })
        holder.withLock { $0 = connector }
        let outcome = await collect(transport(connector).stream(from: phone))
        #expect(connector.openedInterfaces == [.usb] + Array(repeating: .network, count: 5))
        #expect(connector.explainedInterfaces == [.network])  // once, after the last attempt
        #expect(outcome.entries.count == 50)
        #expect(outcome.error as? MobileDeviceError == .localNetworkDenied)
    }

    /// The Local Network check runs once, after the final failed Wi-Fi attempt, and never
    /// stops the retries.
    @Test func failedWifiOpenIsExplainedOnceAfterTheLastAttempt() async {
        let connector = FakeConnector(
            connections: [], interfaces: [.network], transientFailures: 100,
            explanation: { _, _ in MobileDeviceError.localNetworkDenied })
        let outcome = await collect(transport(connector).stream(from: phone))
        #expect(connector.openedIDs.count == 5)
        #expect(connector.explainedInterfaces == [.network])
        #expect(outcome.error as? MobileDeviceError == .localNetworkDenied)
    }

    @Test func failedUSBOpenIsNotExplained() async {
        let connector = FakeConnector(
            connections: [], interfaces: [.usb], transientFailures: 100,
            explanation: { _, _ in MobileDeviceError.localNetworkDenied })
        let outcome = await collect(transport(connector).stream(from: phone))
        #expect(connector.explainedInterfaces.isEmpty)
        #expect(outcome.error as? MobileDeviceError == FakeConnector.transientError)
    }

    /// USB comes back during a Wi-Fi stream: no reopen; the stream stays on Wi-Fi.
    @Test func usbReturningDuringAWifiStreamDoesNotReopen() async throws {
        let wifi = FakeConnection([.data(try statusReply() + (try streamFixture()))], silentWhenDone: true)
        let connector = FakeConnector(connections: [wifi], interfaces: [.network])
        let stream = transport(connector).stream(from: phone)
        let received = Mutex(0)
        let consumer = Task { for try await batch in stream { received.withLock { $0 += batch.count } } }
        #expect(await eventually { received.withLock { $0 } == 50 })
        connector.setInterfaces([.usb, .network])
        try await Task.sleep(for: .milliseconds(300))
        #expect(connector.openedInterfaces == [.network])
        #expect(wifi.closeCount == 0)
        consumer.cancel()
        _ = await consumer.result
    }

    // MARK: Liveness

    /// A silent Wi-Fi link while the device is still on the network keeps streaming; once it
    /// is gone from the network, the stream ends after the liveness timeout.
    @Test func silentWifiEndsOnceTheDeviceLeavesTheNetwork() async throws {
        let wifi = FakeConnection([.data(try statusReply() + (try streamFixture()))], silentWhenDone: true)
        let connector = FakeConnector(connections: [wifi], interfaces: [.network])
        let stream = transport(connector).stream(from: phone)
        let result = Task { await collect(stream) }
        try await Task.sleep(for: .milliseconds(600))  // 3x the liveness timeout, still on the network
        #expect(wifi.closeCount == 0)
        let goneAt = ContinuousClock.now
        connector.setInterfaces([])
        let outcome = await result.value
        #expect(ContinuousClock.now - goneAt < .milliseconds(500))
        #expect(outcome.entries.count == 50)
        #expect(outcome.error as? MobileDeviceError == .networkConnectionLost)
        #expect(wifi.closeCount == 1)
    }

    /// Data keeps arriving: the liveness clock is reset by bytes, so even a device the network
    /// no longer reports keeps streaming while it sends.
    @Test func bytesResetTheLivenessClock() async throws {
        let frames = try streamFixture()
        let holder = Mutex<FakeConnector?>(nil)
        var script: [FakeConnection.Step] = [
            .data(try statusReply()),
            .action { holder.withLock { $0?.setInterfaces([]) } },
        ]
        // 400 ms of quiet link with bytes every 50 ms: never 200 ms without bytes.
        for i in 0..<8 {
            script += [.data(frames.dropFirst(i).prefix(1)), .action { Thread.sleep(forTimeInterval: 0.05) }, .timedOut]
        }
        script.append(.closed)
        let wifi = FakeConnection(script)
        let connector = FakeConnector(connections: [wifi], interfaces: [.network])
        holder.withLock { $0 = connector }
        let outcome = await collect(transport(connector).stream(from: phone))
        #expect(outcome.error as? MobileDeviceError == .connectionClosed)  // not networkConnectionLost
        #expect(wifi.receiveCount > 20)
    }

    /// USB keeps its old behaviour: silence never ends a USB stream.
    @Test func silentUSBIsNotSubjectToLiveness() async throws {
        let usb = FakeConnection([.data(try statusReply() + (try streamFixture()))], silentWhenDone: true)
        let connector = FakeConnector(connections: [usb], interfaces: [.usb])
        let stream = transport(connector).stream(from: phone)
        let consumer = Task { await collect(stream) }
        try await Task.sleep(for: .milliseconds(100))
        connector.setInterfaces([])
        try await Task.sleep(for: .milliseconds(500))
        #expect(usb.closeCount == 0)
        consumer.cancel()
        let outcome = await consumer.value
        #expect(outcome.error == nil)
        #expect(await eventually { usb.closeCount == 1 })
    }

    /// Wi-Fi lost while the device is back on USB: the stream continues over USB.
    @Test func wifiLossWithUSBBackSwitchesToUSB() async throws {
        let frames = try streamFixture()
        let holder = Mutex<FakeConnector?>(nil)
        let wifi = FakeConnection([
            .data(try statusReply() + frames),
            .action { holder.withLock { $0?.setInterfaces([.usb]) } },
        ], silentWhenDone: true)
        let usb = FakeConnection([.data(try statusReply() + frames), .closed])
        let connector = FakeConnector(connections: [wifi, usb], interfaces: [.network])
        holder.withLock { $0 = connector }
        let outcome = await collect(transport(connector).stream(from: phone))
        #expect(connector.openedInterfaces == [.network, .usb])
        #expect(outcome.entries.count == 100)
        #expect(outcome.error as? MobileDeviceError == .connectionClosed)
    }

    @Test func cancellationDuringTheSwitchGraceStopsPromptly() async throws {
        let usb = FakeConnection([.data(try statusReply() + (try streamFixture())), .closed])
        let connector = FakeConnector(connections: [usb], interfaces: [.usb, .network])
        let link = LinkPolicy(failoverGrace: .seconds(10), livenessTimeout: .seconds(10), pollInterval: .milliseconds(10))
        let stream = transport(connector, link: link).stream(from: phone)
        let consumer = Task { await collect(stream) }
        #expect(await eventually { usb.closeCount == 1 })  // now waiting for USB to go
        let cancelledAt = ContinuousClock.now
        consumer.cancel()
        let outcome = await consumer.value
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
        #expect(outcome.error == nil)
        #expect(connector.openedInterfaces == [.usb])
    }
}

struct LocalNetworkAccessTests {
    static let failure = MobileDeviceError.callFailed(function: "AMDeviceConnect", code: -402653083, text: nil)

    @Test func failedWifiOpenIsExplainedWhenAccessIsOff() {
        let explained = LocalNetworkAccess.explain(Self.failure) { true }
        #expect(explained as? MobileDeviceError == .localNetworkDenied)
    }

    @Test func failedWifiOpenKeepsItsErrorOtherwise() {
        let explained = LocalNetworkAccess.explain(Self.failure) { false }
        #expect(explained as? MobileDeviceError == Self.failure)
    }

    /// Unpaired and gone are not access problems: access is not even checked.
    @Test(arguments: [MobileDeviceError.notPaired, .deviceNotConnected])
    func unrelatedFailuresAreNotChecked(_ error: MobileDeviceError) {
        let checked = Mutex(false)
        let explained = LocalNetworkAccess.explain(error) { checked.withLock { $0 = true }; return true }
        #expect(explained as? MobileDeviceError == error)
        #expect(!checked.withLock { $0 })
    }

    /// The browse ends as soon as it is ready (access on) or refused by policy (access off,
    /// or the prompt still pending); other states keep waiting.
    @Test func browseVerdicts() {
        #expect(LocalNetworkAccess.verdict(for: .ready) == false)
        #expect(LocalNetworkAccess.verdict(for: .waiting(.dns(LocalNetworkAccess.policyDenied))) == true)
        #expect(LocalNetworkAccess.verdict(for: .failed(.dns(LocalNetworkAccess.policyDenied))) == true)
        #expect(LocalNetworkAccess.verdict(for: .failed(.posix(.ENETDOWN))) == false)
        #expect(LocalNetworkAccess.verdict(for: .waiting(.posix(.ENETDOWN))) == nil)
        #expect(LocalNetworkAccess.verdict(for: .setup) == nil)
    }

    /// Only produced after the last retry, so it plays no part in the retry decision.
    @Test func localNetworkDeniedIsNotInTheNoRetryList() {
        #expect(OpenRetryPolicy.shouldRetry(MobileDeviceError.localNetworkDenied))
    }

    @Test func messageIsSoft() {
        #expect(MobileDeviceError.localNetworkDenied.description ==
            "Couldn't connect over Wi-Fi: Local Network access looks off for BetterConsole. Allow it when macOS asks, or in System Settings ▸ Privacy & Security ▸ Local Network, then retry.")
    }

    @Test func streamsPreferUSB() {
        #expect(OSTraceStreamSession.preferredInterface([.usb, .network]) == .usb)
        #expect(OSTraceStreamSession.preferredInterface([.network]) == .network)
        #expect(OSTraceStreamSession.preferredInterface([.other]) == nil)
        #expect(OSTraceStreamSession.preferredInterface([]) == nil)
    }
}

// MARK: - Receive timing (a read that returns at once must not spin)

struct ReceiveTimingTests {
    @Test func immediateWouldBlockWaitsOutTheTimeout() {
        let slept = Mutex<[Duration]>([])
        let clock = Mutex(Duration.zero)
        let result = MobileDeviceConnection.receive(
            timeout: .seconds(1), now: { clock.withLock { $0 } },
            read: { (-1, EAGAIN) },
            sleep: { d in slept.withLock { $0.append(d) } })
        #expect(result == .timedOut)
        #expect(slept.withLock { $0 } == [.seconds(1)])
    }

    @Test func readThatWaitedOutTheTimeoutDoesNotSleep() {
        let slept = Mutex<[Duration]>([])
        let clock = Mutex(Duration.zero)
        let result = MobileDeviceConnection.receive(
            timeout: .seconds(1), now: { clock.withLock { $0 } },
            read: { clock.withLock { $0 = .milliseconds(1000) }; return (-1, EAGAIN) },
            sleep: { d in slept.withLock { $0.append(d) } })
        #expect(result == .timedOut)
        #expect(slept.withLock { $0 }.isEmpty)
    }

    @Test func partialWaitSleepsTheRest() {
        let slept = Mutex<[Duration]>([])
        let clock = Mutex(Duration.zero)
        _ = MobileDeviceConnection.receive(
            timeout: .seconds(1), now: { clock.withLock { $0 } },
            read: { clock.withLock { $0 = .milliseconds(20) }; return (-1, EWOULDBLOCK) },
            sleep: { d in slept.withLock { $0.append(d) } })
        #expect(slept.withLock { $0 } == [.milliseconds(980)])
    }

    @Test func otherOutcomes() {
        let zero = { Duration.zero }
        #expect(MobileDeviceConnection.receive(timeout: .seconds(1), now: zero, read: { (12, 0) }, sleep: { _ in }) == .bytes(12))
        #expect(MobileDeviceConnection.receive(timeout: .seconds(1), now: zero, read: { (0, 0) }, sleep: { _ in }) == .closed)
        // TLS failure without errno, at once: a dead connection, not a timeout.
        #expect(MobileDeviceConnection.receive(timeout: .seconds(1), now: zero, read: { (-1, 0) }, sleep: { _ in })
            == .failed("connection lost"))
        #expect(MobileDeviceConnection.receive(timeout: .seconds(1), now: zero, read: { (-1, ECONNRESET) }, sleep: { _ in })
            == .failed(String(cString: strerror(ECONNRESET))))
    }
}
