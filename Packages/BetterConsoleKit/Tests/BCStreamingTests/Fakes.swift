import Foundation
import Synchronization
import BCModel
import BCTransport

func makeEntry(_ id: UInt64, message: String = "m") -> LogEntry {
    LogEntry(
        id: id, date: Date(timeIntervalSince1970: Double(id)), level: .default,
        eventType: "logEvent", process: "proc", message: message)
}

func makeEntries(_ range: Range<UInt64>) -> [LogEntry] { range.map { makeEntry($0) } }

let mac = LogDevice(id: "local", name: "This Mac", kind: .thisMac)
let phoneB = LogDevice(id: "phone-b", name: "B Phone", kind: .physical)
let phoneA = LogDevice(id: "phone-a", name: "A Phone", kind: .physical)
let simA = LogDevice(id: "sim-a", name: "A Sim", kind: .simulator)
let simB = LogDevice(id: "sim-b", name: "B Sim", kind: .simulator)

struct FakeError: Error, CustomStringConvertible {
    var description: String { "child exited" }
}

/// A transport whose streams are driven by the test. Every `stream(from:)` call creates a new
/// stream with its own continuation; the fake records calls and terminations.
final class FakeTransport: LogTransport {
    private struct Stream {
        let continuation: AsyncThrowingStream<[LogEntry], Error>.Continuation
        var terminated = false
        var cancelled = false
    }
    private let state = Mutex<[Stream]>([])
    private let supported: Set<LogDevice.ID>?

    /// `supported == nil` supports every device.
    init(supported: Set<LogDevice.ID>? = nil) { self.supported = supported }

    func supports(_ device: LogDevice) -> Bool { supported?.contains(device.id) ?? true }

    func stream(from device: LogDevice) -> AsyncThrowingStream<[LogEntry], Error> {
        let (stream, continuation) = AsyncThrowingStream<[LogEntry], Error>.makeStream()
        let index = state.withLock { streams in
            streams.append(Stream(continuation: continuation))
            return streams.count - 1
        }
        continuation.onTermination = { [weak self] reason in
            self?.state.withLock {
                $0[index].terminated = true
                if case .cancelled = reason { $0[index].cancelled = true }
            }
        }
        return stream
    }

    var callCount: Int { state.withLock { $0.count } }
    /// Streams that have been started and not terminated.
    var activeCount: Int { state.withLock { $0.filter { !$0.terminated }.count } }
    func isTerminated(_ index: Int) -> Bool { state.withLock { $0[index].terminated } }
    func wasCancelled(_ index: Int) -> Bool { state.withLock { $0[index].cancelled } }

    /// Yields into the most recent stream (or `index`).
    func yield(_ entries: [LogEntry], index: Int? = nil) {
        let c = state.withLock { $0[index ?? $0.count - 1].continuation }
        c.yield(entries)
    }

    func finish(throwing error: Error? = nil, index: Int? = nil) {
        let c = state.withLock { $0[index ?? $0.count - 1].continuation }
        c.finish(throwing: error)
    }
}

/// A discovery whose device lists are pushed by the test.
final class FakeDiscovery: DeviceDiscovery {
    private let stream: AsyncStream<[LogDevice]>
    private let continuation: AsyncStream<[LogDevice]>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func devices() -> AsyncStream<[LogDevice]> { stream }
    func push(_ devices: [LogDevice]) { continuation.yield(devices) }
}

/// Polls `condition` until it holds or `timeout` elapses.
@MainActor
func eventually(
    timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}
