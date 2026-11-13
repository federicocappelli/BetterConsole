import BCModel
import Foundation
import Synchronization
import Testing
@testable import BCTransport

/// Serialized: `terminateAllKillsChildren` kills every registered child, which would
/// cut short streams started by other tests in this suite if they ran in parallel.
@Suite(.serialized) struct ProcessLogTransportTests {
    private static let mac = LogDevice(id: "local", name: "This Mac", kind: .thisMac)

    private static func scriptPath() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "emit", withExtension: "sh", subdirectory: "Fixtures"))
        return url.path
    }

    /// Runs the fixture through `/bin/sh` (resources may lose the exec bit).
    private static func transport(_ args: [String]) throws -> ProcessLogTransport {
        let script = try scriptPath()
        return ProcessLogTransport(commandFor: { _ in
            (URL(fileURLWithPath: "/bin/sh"), [script] + args)
        })
    }

    private static func isGone(_ pid: Int32) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    /// Polls until `pid` (and its process group) no longer exist, or `timeout` passes.
    private static func waitUntilGone(_ pid: Int32, timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if isGone(pid), kill(-pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isGone(pid)
    }

    /// Starts a hanging stream in a task, returns the task and the child's pid
    /// (the fixture writes its own pid into `processID`).
    private static func startHanging(mode: String = "hang") async throws -> (Task<Void, Never>, Int32) {
        let stream = try transport(["1", mode]).stream(from: mac)
        let (pids, pidContinuation) = AsyncStream.makeStream(of: Int32.self)
        let task = Task {
            do {
                for try await batch in stream {
                    if let pid = batch.first?.pid { pidContinuation.yield(pid) }
                }
            } catch {}
            pidContinuation.finish()
        }
        var iterator = pids.makeAsyncIterator()
        let pid = try #require(await iterator.next())
        return (task, pid)
    }

    @Test func emitsAllEntriesInBatches() async throws {
        let stream = try Self.transport(["2500"]).stream(from: Self.mac)
        var batches: [[LogEntry]] = []
        await #expect(throws: TransportError.processExited(status: 0)) {
            for try await batch in stream { batches.append(batch) }
        }
        let entries = batches.flatMap { $0 }
        #expect(entries.count == 2500)
        #expect(batches.count >= 3)
        #expect(batches.allSatisfy { !$0.isEmpty && $0.count <= 1000 })
        #expect(entries.first?.message == "line 0")
        #expect(entries.last?.message == "line 2499")
        #expect(entries.map(\.id) == Array(1...2500))
    }

    @Test func cancellationKillsChild() async throws {
        let (task, pid) = try await Self.startHanging()
        #expect(!Self.isGone(pid))
        task.cancel()
        #expect(await Self.waitUntilGone(pid))
        await task.value
    }

    @Test func cancellationEscalatesToSIGKILL() async throws {
        let (task, pid) = try await Self.startHanging(mode: "ignoreterm")
        task.cancel()
        // SIGTERM is ignored by sh and sleep; the 1 s SIGKILL escalation must take both.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!Self.isGone(pid))
        #expect(await Self.waitUntilGone(pid, timeout: .seconds(2)))
        await task.value
    }

    /// A descendant outside our process group (like the in-simulator `log stream` that
    /// `simctl spawn` launches) keeps the pipe open after the leader exits. The stream must
    /// still finish, within the 200 ms drain, and close the read end.
    @Test func leaderExitFinishesDespiteOrphanHoldingPipe() async throws {
        let stream = try Self.transport(["2", "orphan"]).stream(from: Self.mac)
        let orphan = Mutex<Int32?>(nil)
        let consumer = Task { () -> ([LogEntry], Error?) in
            var entries: [LogEntry] = []
            do {
                for try await batch in stream {
                    entries += batch
                    for entry in batch where entry.message.hasPrefix("orphan ") {
                        let pid = Int32(entry.message.dropFirst("orphan ".count))
                        orphan.withLock { $0 = pid }
                    }
                }
                return (entries, nil)
            } catch {
                return (entries, error)
            }
        }
        // Watchdog: if the stream has not finished in 2 s, kill the orphan to unblock it.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, let pid = orphan.withLock({ $0 }) { kill(pid, SIGKILL) }
        }
        let start = ContinuousClock.now
        let (entries, error) = await consumer.value
        let elapsed = ContinuousClock.now - start
        watchdog.cancel()
        let orphanPid = try #require(orphan.withLock { $0 })
        defer { kill(orphanPid, SIGKILL) }

        #expect(elapsed < .seconds(1))
        #expect(entries.count == 3)
        #expect(error as? TransportError == .processExited(status: 0))
        #expect(!Self.isGone(orphanPid), "orphan should still be running; the stream must not have waited for it")
    }

    /// Instant-exit children must not leak their session (onTermination retain cycle).
    @Test func sessionsReleasedAfterStreamsFinish() async throws {
        let transport = ProcessLogTransport(commandFor: { _ in
            (URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 0"])
        })
        for _ in 0..<20 {
            await #expect(throws: TransportError.processExited(status: 0)) {
                for try await _ in transport.stream(from: Self.mac) {}
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while ProcessSession.liveCount.load(ordering: .relaxed) > 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(ProcessSession.liveCount.load(ordering: .relaxed) == 0)
    }

    @Test func terminateAllKillsChildren() async throws {
        let (task1, pid1) = try await Self.startHanging()
        let (task2, pid2) = try await Self.startHanging()
        #expect(pid1 != pid2)
        ChildProcessRegistry.shared.terminateAll()
        #expect(await Self.waitUntilGone(pid1))
        #expect(await Self.waitUntilGone(pid2))
        // Both streams end on their own once the children are gone.
        await task1.value
        await task2.value
    }

    @Test func unexpectedExitThrows() async throws {
        let stream = try Self.transport(["3"]).stream(from: Self.mac)
        var entries: [LogEntry] = []
        await #expect(throws: TransportError.processExited(status: 0)) {
            for try await batch in stream { entries += batch }
        }
        #expect(entries.count == 3)
    }

    @Test func nonzeroExitStatusReported() async throws {
        let transport = ProcessLogTransport(commandFor: { _ in
            (URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 7"])
        })
        await #expect(throws: TransportError.processExited(status: 7)) {
            for try await _ in transport.stream(from: Self.mac) {}
        }
    }

    @Test func launchFailureThrows() async throws {
        let transport = ProcessLogTransport(commandFor: { _ in
            (URL(fileURLWithPath: "/nonexistent/bc-no-such-binary"), [])
        })
        var thrown: Error?
        do {
            for try await _ in transport.stream(from: Self.mac) {}
        } catch {
            thrown = error
        }
        guard case .launchFailed = thrown as? TransportError else {
            Issue.record("expected launchFailed, got \(String(describing: thrown))")
            return
        }
    }

    @Test func unsupportedDeviceThrowsLaunchFailed() async throws {
        let phone = LogDevice(id: "00008150-0001", name: "iPhone", kind: .physical)
        let transport = ProcessLogTransport()
        #expect(!transport.supports(phone))
        var thrown: Error?
        do {
            for try await _ in transport.stream(from: phone) {}
        } catch {
            thrown = error
        }
        guard case .launchFailed = thrown as? TransportError else {
            Issue.record("expected launchFailed, got \(String(describing: thrown))")
            return
        }
    }

    /// Session banners show `String(describing:)` of the error, so it must read as a sentence.
    @Test func errorDescriptionsArePlainSentences() {
        let exited = TransportError.processExited(status: 15)
        #expect(String(describing: exited) == "The log process exited unexpectedly (status 15).")
        #expect(exited.localizedDescription == "The log process exited unexpectedly (status 15).")
        let launch = TransportError.launchFailed("/usr/bin/log: No such file or directory")
        #expect(String(describing: launch) == "Couldn't start the log process: /usr/bin/log: No such file or directory.")
        #expect(launch.localizedDescription == String(describing: launch))
    }

    @Test func defaultCommands() throws {
        let mac = try #require(ProcessLogTransport.defaultCommand(Self.mac))
        #expect(mac.executable == URL(fileURLWithPath: "/usr/bin/log"))
        #expect(mac.arguments == ["stream", "--style", "ndjson", "--level", "debug"])

        let udid = "5A1B2C3D-0000-4000-8000-ABCDEF012345"
        let sim = LogDevice(id: udid, name: "iPhone 18 Pro", kind: .simulator)
        let simCommand = try #require(ProcessLogTransport.defaultCommand(sim))
        #expect(simCommand.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(simCommand.arguments == ["simctl", "spawn", udid, "log", "stream", "--style", "ndjson", "--level", "debug"])

        let phone = LogDevice(id: "00008150-0001", name: "iPhone", kind: .physical)
        #expect(ProcessLogTransport.defaultCommand(phone) == nil)

        let transport = ProcessLogTransport()
        #expect(transport.supports(Self.mac))
        #expect(transport.supports(sim))
        #expect(!transport.supports(phone))
    }
}
