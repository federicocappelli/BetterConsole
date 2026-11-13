import BCModel
import BCTransport
import Foundation
import Synchronization
import Testing
@testable import BCMobileDevice

// MARK: - Fakes

/// A scripted service connection. `receive` pops steps in order; when the script runs out it
/// blocks like a socket with no data until `interrupt()` (as `shutdown` would), then reports
/// the connection closed.
final class FakeConnection: OSTraceConnection {
    enum Step: Sendable { case data(Data), timedOut, closed, failed(String) }

    private struct State {
        var script: [Step]
        var interrupted = false
        var closeCount = 0
        var receiveCount = 0
    }
    private let state: Mutex<State>
    private let wake = DispatchSemaphore(value: 0)

    init(_ script: [Step]) { state = Mutex(State(script: script)) }

    func receive(into buffer: UnsafeMutableRawBufferPointer) -> ReceiveResult {
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
        case nil:
            _ = wake.wait(timeout: .now() + 10)
            return .closed
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

final class FakeConnector: OSTraceConnector {
    private let connection: FakeConnection?
    private let openError: (any Error)?
    private let openGate: DispatchSemaphore?
    private let opened = Mutex<[String]>([])
    /// The first `transientFailures` opens throw a retryable error (lockdown not ready yet).
    private let transientFailures: Int

    init(_ connection: FakeConnection?, openError: (any Error)? = nil, openGate: DispatchSemaphore? = nil,
         transientFailures: Int = 0) {
        self.connection = connection
        self.openError = openError
        self.openGate = openGate
        self.transientFailures = transientFailures
    }

    static let transientError = MobileDeviceError.callFailed(function: "AMDeviceStartSession", code: -402653158, text: nil)

    func open(deviceID: String) throws -> any OSTraceConnection {
        let attempt = opened.withLock { $0.append(deviceID); return $0.count }
        openGate?.wait()
        if attempt <= transientFailures { throw Self.transientError }
        if let openError { throw openError }
        return connection!
    }

    var openedIDs: [String] { opened.withLock { $0 } }
}

// MARK: - Helpers

let phone = LogDevice(id: "00000000-0000000000000000", name: "PhoneVac", kind: .physical)

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
