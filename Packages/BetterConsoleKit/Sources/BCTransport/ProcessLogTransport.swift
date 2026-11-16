import BCModel
import Foundation
import Synchronization

/// Streams logs by running a child process that prints `log stream --style ndjson` output:
/// `/usr/bin/log` for this Mac, `xcrun simctl spawn <udid> log` for simulators.
public struct ProcessLogTransport: LogTransport {
    public typealias Command = (executable: URL, arguments: [String])

    private let commandFor: @Sendable (LogDevice) -> Command?

    public init(commandFor: @escaping @Sendable (LogDevice) -> Command? = ProcessLogTransport.defaultCommand) {
        self.commandFor = commandFor
    }

    public static func defaultCommand(_ d: LogDevice) -> Command? {
        let streamArguments = ["stream", "--style", "ndjson", "--level", "debug"]
        switch d.kind {
        case .thisMac:
            return (URL(fileURLWithPath: "/usr/bin/log"), streamArguments)
        case .simulator:
            return (URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl", "spawn", d.id, "log"] + streamArguments)
        case .physical, .file:
            return nil
        }
    }

    public func supports(_ device: LogDevice) -> Bool {
        commandFor(device) != nil
    }

    public func stream(from device: LogDevice) -> AsyncThrowingStream<[LogEntry], Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [LogEntry].self, throwing: Error.self)
        guard let command = commandFor(device) else {
            continuation.finish(throwing: TransportError.launchFailed("No log command for device \(device.id)"))
            return stream
        }
        // Install the handler before spawning: a child that exits at once can finish the
        // stream before `launch` returns, and a handler set after that would never run
        // (leaving continuation -> handler -> session -> continuation alive forever).
        let slot = SessionSlot()
        continuation.onTermination = { termination in
            // Runs synchronously inside `continuation.finish()`, which ProcessSession calls
            // while holding its state lock: on `.finished` this must never take that lock.
            // Only `.cancelled` (never delivered from inside finish) calls into the session.
            let cancelled = if case .cancelled = termination { true } else { false }
            if let session = slot.end(cancelled: cancelled), cancelled {
                session.terminate()
            }
        }
        do {
            let session = try ProcessSession.launch(command, continuation: continuation)
            if slot.install(session) { session.terminate() }
        } catch {
            continuation.finish(throwing: error)
        }
        return stream
    }
}

/// Hands the session to `onTermination`, which is installed before the session exists.
private final class SessionSlot: Sendable {
    private enum Phase {
        case launching
        case running(ProcessSession)
        case ended(cancelled: Bool)
    }

    private let phase = Mutex(Phase.launching)

    /// Stores the session. Returns true if the consumer already cancelled, so the caller
    /// must terminate it. A stream that already finished keeps no reference.
    func install(_ session: ProcessSession) -> Bool {
        phase.withLock { phase in
            switch phase {
            case .launching:
                phase = .running(session)
                return false
            case .running:
                return false
            case .ended(let cancelled):
                return cancelled
            }
        }
    }

    /// Marks the stream ended and returns (releasing) the session, if installed.
    func end(cancelled: Bool) -> ProcessSession? {
        phase.withLock { phase in
            let session: ProcessSession? = if case .running(let s) = phase { s } else { nil }
            phase = .ended(cancelled: cancelled)
            return session
        }
    }
}

/// One running child: reads its stdout, decodes and batches entries, reaps it.
///
/// Process group: spawned with `posix_spawn` + `POSIX_SPAWN_SETPGROUP` (pgroup 0), so the
/// child leads its own group (pgid == pid) from its first instruction — no window where
/// a signal to the group misses it, unlike `Process` + a post-launch `setpgid`. Signals go
/// to `-pid`, which also reaches `xcrun simctl spawn`'s descendants.
///
/// Simulators: `simctl spawn` runs `log stream` inside the simulator, parented by
/// launchd_sim in its own process group, so group signals never reach it. Measured on an
/// iOS 26 simulator: SIGTERM to simctl removes it within ~10 ms, but after SIGKILL to simctl
/// it keeps running for as long as our pipe's read end is open. So once the leader has
/// exited we drain for at most `drainAfterExit` and then close the read end: the orphan
/// gets SIGPIPE on its next write (~20 ms with `--level debug`) and the stream finishes
/// even though EOF never arrives.
///
/// Reaping: a waiter thread first waits for the leader with `WNOWAIT`, so the zombie keeps
/// the pgid reserved while the group is swept with SIGKILL (orphaned descendants would
/// otherwise hold the pipe open and could outlive us). Only then is the leader reaped.
/// Every signal to the group is sent while the leader is known not to be reaped, so a
/// recycled pgid is never signalled.
///
/// Concurrency: the readability handler, the batch timer, the waiter thread and
/// cancellation all touch `state` only through its `Mutex`. Batches are yielded while
/// holding the lock so they reach the continuation in order.
final class ProcessSession: Sendable {
    static let maxBatchSize = 1_000
    static let maxBatchDelay: DispatchTimeInterval = .milliseconds(50)
    static let killGrace: DispatchTimeInterval = .seconds(1)
    /// After the leader exits, how long to wait for EOF before closing the read end.
    static let drainAfterExit: DispatchTimeInterval = .milliseconds(200)
    /// A partial line longer than this without a newline is dropped.
    static let maxLineLength = 1 << 20

    private struct State {
        var splitter = LineSplitter(maxLineLength: ProcessSession.maxLineLength)
        var decoder = LogEntryDecoder()
        var pending: [LogEntry] = []
        /// Bumped on every flush so a stale batch timer does nothing.
        var timerGeneration = 0
        var timerArmed = false
        var reachedEOF = false
        var exitStatus: Int32?
        /// Set before the leader is reaped; until then its pid (= pgid) cannot be reused.
        var leaderGone = false
        var cancelled = false
        var finished = false
        /// Set under the lock by whichever path first gives up the pipe's fd number: the
        /// readability handler (before it closes the fd) or `stopReadingAfterExit` (when it
        /// swaps in /dev/null). The other path must then leave the fd number alone, since
        /// once closed it may already belong to an unrelated descriptor.
        var readClosed = false
    }

    let pid: pid_t
    private let readFD: Int32
    private let output: FileHandle
    private let continuation: AsyncThrowingStream<[LogEntry], Error>.Continuation
    private let state = Mutex(State())

    /// Sessions alive in this process; tests use it to detect leaks.
    static let liveCount = Atomic<Int>(0)

    private init(pid: pid_t, readFD: Int32, continuation: AsyncThrowingStream<[LogEntry], Error>.Continuation) {
        self.pid = pid
        self.readFD = readFD
        self.output = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        self.continuation = continuation
        Self.liveCount.add(1, ordering: .relaxed)
    }

    deinit {
        Self.liveCount.subtract(1, ordering: .relaxed)
    }

    // MARK: Launch

    static func launch(
        _ command: ProcessLogTransport.Command,
        continuation: AsyncThrowingStream<[LogEntry], Error>.Continuation
    ) throws -> ProcessSession {
        let (pid, readFD) = try spawn(command)
        let session = ProcessSession(pid: pid, readFD: readFD, continuation: continuation)
        ChildProcessRegistry.shared.register(session)
        session.output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                session.markReadClosed()
                try? handle.close()
                session.receivedEOF()
            } else {
                session.received(data)
            }
        }
        let waiter = Thread { session.waitForExit() }
        waiter.name = "BCTransport.reaper.\(pid)"
        waiter.start()
        return session
    }

    /// Spawns `command` with stdout on a new pipe, stdin/stderr on /dev/null, in its own
    /// process group. Returns the pid and the pipe's read end.
    private static func spawn(_ command: ProcessLogTransport.Command) throws -> (pid_t, Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw TransportError.launchFailed("pipe: \(String(cString: strerror(errno)))") }
        let (readFD, writeFD) = (fds[0], fds[1])
        // Keep both ends out of children forked elsewhere in the app (no pipe2 on Darwin,
        // so there is a brief window). Our own child gets fd 1 via dup2 below.
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT: the child inherits only fds 0-2 set up above.
        // SETSIGDEF/SETSIGMASK: start with default handlers and nothing blocked.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let path = command.executable.path
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + command.arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        close(writeFD)
        guard result == 0 else {
            close(readFD)
            throw TransportError.launchFailed("\(path): \(String(cString: strerror(result)))")
        }
        return (pid, readFD)
    }

    // MARK: Output

    private func received(_ data: Data) {
        state.withLock { state in
            guard !state.finished else { return }
            for line in state.splitter.feed(data) {
                guard let entry = state.decoder.decode(line: line) else { continue }
                state.pending.append(entry)
                if state.pending.count >= Self.maxBatchSize { flush(&state) }
            }
            armTimerIfNeeded(&state)
        }
    }

    /// Called by the readability handler before it closes the fd, so a concurrent
    /// `stopReadingAfterExit` cannot `dup2` onto a closed (possibly reused) fd number.
    private func markReadClosed() {
        state.withLock { $0.readClosed = true }
    }

    private func receivedEOF() {
        state.withLock { state in
            state.reachedEOF = true
            finishIfDone(&state)
        }
    }

    /// Starts the 50 ms clock when the first unflushed entry arrives.
    private func armTimerIfNeeded(_ state: inout State) {
        guard !state.pending.isEmpty, !state.timerArmed else { return }
        state.timerArmed = true
        let generation = state.timerGeneration
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.maxBatchDelay) { [weak self] in
            guard let self else { return }
            self.state.withLock { current in
                guard current.timerArmed, current.timerGeneration == generation, !current.finished else { return }
                flush(&current)
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

    /// Finishes the stream once stdout is drained and the leader has been reaped.
    private func finishIfDone(_ state: inout State) {
        guard state.reachedEOF, let status = state.exitStatus, !state.finished else { return }
        if let partial = state.splitter.finish(), let entry = state.decoder.decode(line: partial) {
            state.pending.append(entry)
        }
        flush(&state)
        state.finished = true
        if state.cancelled {
            continuation.finish()
        } else {
            continuation.finish(throwing: TransportError.processExited(status: status))
        }
    }

    // MARK: Exit and termination

    private func waitForExit() {
        // Wait without reaping, so the pgid stays reserved for the sweep below.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        // Sweep descendants left in the group (e.g. under `xcrun simctl spawn`).
        state.withLock { state in
            _ = kill(-pid, SIGKILL)
            state.leaderGone = true
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        ChildProcessRegistry.shared.unregister(pid)

        let signal = status & 0x7f
        let exitStatus = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        let finished = state.withLock { state in
            state.exitStatus = exitStatus
            finishIfDone(&state)
            return state.finished
        }
        guard !finished else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.drainAfterExit) { [weak self] in
            self?.stopReadingAfterExit()
        }
    }

    /// The leader is gone but the pipe never reached EOF: something outside our group holds
    /// the write end. Close our read end and finish with what we have.
    private func stopReadingAfterExit() {
        // dup2 swaps /dev/null in under the same fd number. The pipe's read end is closed
        // (the writer gets SIGPIPE), while a handler already inside `availableData` reads
        // EOF from /dev/null instead of hitting a closed or reused fd. FileHandle still
        // owns and later closes the fd.
        // The check and the dup2 share one critical section with the handler's
        // `markReadClosed`: if the handler got there first, the fd number may already be
        // closed and reused, so we must not touch it (the handler finishes the stream).
        let swapped = state.withLock { state -> Bool in
            guard !state.finished, !state.readClosed else { return false }
            let devNull = open("/dev/null", O_RDONLY | O_CLOEXEC)
            if devNull >= 0 {
                _ = dup2(devNull, readFD)
                close(devNull)
            }
            state.readClosed = true
            return true
        }
        guard swapped else { return }
        output.readabilityHandler = nil
        state.withLock { state in
            state.reachedEOF = true
            finishIfDone(&state)
        }
    }

    var isLeaderGone: Bool {
        state.withLock { $0.leaderGone }
    }

    /// SIGTERM to the group now, SIGKILL after `killGrace` if the leader is still alive.
    func terminate() {
        let signalled = state.withLock { state -> Bool in
            state.cancelled = true
            guard !state.leaderGone else { return false }
            _ = kill(-pid, SIGTERM)
            return true
        }
        guard signalled else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGrace) { [weak self] in
            self?.forceKill()
        }
    }

    /// SIGKILL to the group if the leader has not exited yet.
    func forceKill() {
        state.withLock { state in
            state.cancelled = true
            guard !state.leaderGone else { return }
            _ = kill(-pid, SIGKILL)
        }
    }
}
