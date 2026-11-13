import BCModel
import Foundation

/// Polls `simctl` for booted simulators and emits the list whenever it changes.
public struct SimulatorDiscovery: DeviceDiscovery {
    public typealias Runner = @Sendable () async throws -> Data

    private let interval: Duration
    private let runner: Runner

    public init(interval: Duration = .seconds(3), runner: @escaping Runner = SimulatorDiscovery.runSimctl) {
        self.interval = interval
        self.runner = runner
    }

    public func devices() -> AsyncStream<[LogDevice]> {
        let interval = interval
        let runner = runner
        return AsyncStream { continuation in
            let task = Task {
                var last: [LogDevice]?
                while !Task.isCancelled {
                    let current: [LogDevice]
                    do {
                        current = try Self.parse(try await runner())
                    } catch {
                        // One failed or timed-out simctl call must not report every simulator
                        // as gone (their sessions would disconnect and lose logs). Keep the
                        // last list; only a failure before any list has been emitted yields
                        // [] so consumers still get an initial value.
                        current = last ?? []
                    }
                    if current != last {
                        last = current
                        continuation.yield(current)
                    }
                    do { try await Task.sleep(for: interval) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Parsing

    private struct Listing: Decodable {
        struct Entry: Decodable {
            let udid: String
            let name: String
            let deviceTypeIdentifier: String?
            let state: String?
        }
        let devices: [String: [Entry]]
    }

    public static func parse(_ json: Data) throws -> [LogDevice] {
        let listing = try JSONDecoder().decode(Listing.self, from: json)
        var result: [LogDevice] = []
        for (runtime, entries) in listing.devices {
            let os = osVersion(fromRuntime: runtime)
            for entry in entries where entry.state == "Booted" {
                result.append(LogDevice(
                    id: entry.udid,
                    name: entry.name,
                    kind: .simulator,
                    model: entry.deviceTypeIdentifier.map(modelName(fromTypeIdentifier:)),
                    osVersion: os
                ))
            }
        }
        return result.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-2` -> `iOS 27.2`.
    static func osVersion(fromRuntime key: String) -> String? {
        let tail = key.split(separator: ".").last.map(String.init) ?? key
        let parts = tail.split(separator: "-").map(String.init)
        guard let platform = parts.first else { return nil }
        let numbers = parts.dropFirst().prefix { Int($0) != nil }
        guard !numbers.isEmpty else { return platform }
        return "\(platform) \(numbers.joined(separator: "."))"
    }

    /// `com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro` -> `iPhone 16 Pro`.
    static func modelName(fromTypeIdentifier id: String) -> String {
        let tail = id.split(separator: ".").last.map(String.init) ?? id
        return tail.replacingOccurrences(of: "-", with: " ")
    }

    // MARK: Real runner

    @Sendable public static func runSimctl() async throws -> Data {
        try await runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "booted", "-j"],
            timeout: .seconds(10)
        )
    }

    enum SimctlError: Error { case failed(Int32), timedOut }

    /// Runs a short-lived child without blocking a cooperative-pool thread. A hung child is
    /// terminated after `timeout` or when the calling task is cancelled; both throw.
    static func runProcess(executable: String, arguments: [String], timeout: Duration) async throws -> Data {
        let run = ProcessRun()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(executable: executable, arguments: arguments, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            run.terminate(timedOut: false)
        }
    }
}

private final class ProcessRun: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var buffer = Data()
    private var cancelled = false
    private var launched = false
    private var timedOut = false

    func start(executable: String, arguments: [String], timeout: Duration, continuation: CheckedContinuation<Data, Error>) {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            lock.withLock { buffer.append(chunk) }
        }
        process.terminationHandler = { [self] process in
            reader.readabilityHandler = nil
            let status = process.terminationStatus
            let wasTimedOut = lock.withLock { timedOut }
            var data = Data()
            if status == 0, !wasTimedOut { data = (try? reader.readToEnd()) ?? Data() }
            lock.withLock { buffer.append(data) }
            let result = lock.withLock { (buffer, timedOut) }
            if result.1 { continuation.resume(throwing: SimulatorDiscovery.SimctlError.timedOut) }
            else if status != 0 { continuation.resume(throwing: SimulatorDiscovery.SimctlError.failed(status)) }
            else { continuation.resume(returning: result.0) }
        }
        let skip = lock.withLock { cancelled }
        if skip { continuation.resume(throwing: CancellationError()); return }
        do {
            try process.run()
            lock.withLock { launched = true }
        } catch {
            reader.readabilityHandler = nil
            continuation.resume(throwing: error)
            return
        }
        if lock.withLock({ cancelled }) { terminate(timedOut: false) }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in terminate(timedOut: true) }
    }

    func terminate(timedOut: Bool) {
        let shouldKill: Bool = lock.withLock {
            if !timedOut { cancelled = true }
            guard launched, process.isRunning else { return false }
            if timedOut { self.timedOut = true }
            return true
        }
        if shouldKill { process.terminate() }
    }
}
