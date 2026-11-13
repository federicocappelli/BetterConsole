import BCModel
import Foundation
import Testing
@testable import BCTransport

/// Opt-in: needs a booted simulator. Run with
/// `BC_SIM_UDID=<udid> swift test --filter SimulatorTransportIntegrationTests`.
/// Simulator processes are host processes, so host `pgrep` sees the in-simulator `log`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BC_SIM_UDID"] != nil))
struct SimulatorTransportIntegrationTests {
    private static let udid = ProcessInfo.processInfo.environment["BC_SIM_UDID"] ?? ""
    private static let device = LogDevice(id: udid, name: "Simulator", kind: .simulator)
    /// Matches only the in-simulator `log` we spawn (not the `simctl` leader, whose
    /// command line starts with the simctl path).
    private static let pattern = "log stream --style ndjson --level debug"

    private static func inSimLogPids() -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "^\(pattern)$"]
        let out = Pipe()
        pgrep.standardOutput = out
        try? pgrep.run()
        pgrep.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { Int32($0) }
    }

    private static func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func cancelRemovesInSimulatorLog() async throws {
        #expect(Self.inSimLogPids().isEmpty, "stale in-sim log stream before test")
        let stream = ProcessLogTransport().stream(from: Self.device)
        let (firstBatch, signal) = AsyncStream.makeStream(of: Int.self)
        let task = Task {
            do { for try await batch in stream { signal.yield(batch.count) } } catch {}
            signal.finish()
        }
        var it = firstBatch.makeAsyncIterator()
        let count = try #require(await it.next())
        #expect(count > 0)
        #expect(!Self.inSimLogPids().isEmpty)
        task.cancel()
        await task.value
        #expect(await Self.waitUntil(.seconds(2)) { Self.inSimLogPids().isEmpty })
    }

    /// SIGKILL to simctl orphans the in-sim `log`; the transport must still finish and,
    /// by closing its read end, take the orphan down via SIGPIPE.
    @Test func sigkilledSimctlStillFinishesAndOrphanDies() async throws {
        #expect(Self.inSimLogPids().isEmpty, "stale in-sim log stream before test")
        let before = Set(ChildProcessRegistry.shared.pids)
        let stream = ProcessLogTransport().stream(from: Self.device)
        let leader = try #require(Set(ChildProcessRegistry.shared.pids).subtracting(before).first)
        let (firstBatch, signal) = AsyncStream.makeStream(of: Int.self)
        let task = Task { () -> Error? in
            defer { signal.finish() }
            do { for try await batch in stream { signal.yield(batch.count) } } catch { return error }
            return nil
        }
        var it = firstBatch.makeAsyncIterator()
        _ = try #require(await it.next())
        let orphans = Self.inSimLogPids()
        #expect(!orphans.isEmpty)

        let start = ContinuousClock.now
        kill(leader, SIGKILL)
        let error = await task.value
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(error as? TransportError == .processExited(status: 128 + SIGKILL))
        #expect(await Self.waitUntil(.seconds(2)) { Self.inSimLogPids().isEmpty })
        for pid in Self.inSimLogPids() { kill(pid, SIGTERM) }
    }
}
