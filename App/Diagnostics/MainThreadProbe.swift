import AppKit
import Darwin

/// Throughput diagnostics, off unless `BETTERCONSOLE_PROBE=<file>` is set in the environment
/// (see docs/RELEASE.md, "Throughput check"). Measures how long the main run loop stays busy
/// per iteration (from waking up to going back to sleep) and appends one line per
/// `window` to the file: iterations over 16 ms, the longest one, table updates, messages
/// received per second, dropped and stored counts, and the process's resident memory; every
/// 30 s also one line per device session (state and messages received).
@MainActor
final class MainThreadProbe {
    struct Counters {
        var received = 0
        var dropped = 0
        var stored = 0
        var estimatedBytes = 0
    }

    static let environmentKey = "BETTERCONSOLE_PROBE"
    static private(set) var shared: MainThreadProbe?

    private let output: FileHandle
    private let counters: @MainActor () -> Counters
    private let sessions: @MainActor () -> [String]
    private let window: Duration = .seconds(5)
    private let budget: Duration = .milliseconds(16)
    private let clock = ContinuousClock()

    private var iterationStart: ContinuousClock.Instant?
    private var iterations = 0
    private var overBudget = 0
    private var longest: Duration = .zero
    private var updates = 0
    private var updateTotal: Duration = .zero
    private var updateLongest: Duration = .zero
    private var lastReceived = 0
    private var windowIndex = 0
    private var observer: CFRunLoopObserver?

    /// Starts the probe if the environment asks for it. Returns whether it is running.
    @discardableResult
    static func startIfRequested(
        counters: @escaping @MainActor () -> Counters,
        sessions: @escaping @MainActor () -> [String]
    ) -> Bool {
        guard shared == nil, let path = ProcessInfo.processInfo.environment[environmentKey],
              !path.isEmpty
        else { return false }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return false }
        let probe = MainThreadProbe(output: handle, counters: counters, sessions: sessions)
        shared = probe
        probe.start()
        return true
    }

    private init(
        output: FileHandle, counters: @escaping @MainActor () -> Counters,
        sessions: @escaping @MainActor () -> [String]
    ) {
        self.output = output
        self.counters = counters
        self.sessions = sessions
    }

    /// Called by the log table with the duration of each update it applies.
    static func recordUpdate(_ duration: Duration) {
        guard let shared else { return }
        shared.updates += 1
        shared.updateTotal += duration
        shared.updateLongest = max(shared.updateLongest, duration)
    }

    private func start() {
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated { [weak self] in self?.observe(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        write("window  iters  >16ms  max_ms  updates  upd_avg_ms  upd_max_ms  recv/s  dropped  stored  est_MB  rss_MB  visible")
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: self.window)
                self.flush()
            }
        }
    }

    private func observe(_ activity: CFRunLoopActivity) {
        if activity == .afterWaiting {
            iterationStart = clock.now
        } else if let start = iterationStart {
            let busy = clock.now - start
            iterationStart = nil
            iterations += 1
            if busy > budget { overBudget += 1 }
            longest = max(longest, busy)
        }
    }

    private func flush() {
        let c = counters()
        let seconds = Double(window.components.seconds)
        let received = Int(Double(c.received - lastReceived) / seconds)
        lastReceived = c.received
        windowIndex += 1
        let line = String(
            format: "%6d  %5d  %5d  %6.1f  %7d  %10.2f  %10.1f  %6d  %7d  %6d  %6.0f  %6.0f",
            windowIndex, iterations, overBudget, Self.ms(longest), updates,
            updates > 0 ? Self.ms(updateTotal) / Double(updates) : 0, Self.ms(updateLongest),
            received, c.dropped, c.stored, Double(c.estimatedBytes) / 1_048_576,
            Double(Self.residentBytes()) / 1_048_576) + "  " + Self.visibility()
        write(line)
        // Every 6th window (30 s): one line per session, to see which devices stream.
        if windowIndex % 6 == 1 {
            for session in sessions() { write("        session \(session)") }
        }
        iterations = 0
        overBudget = 0
        longest = .zero
        updates = 0
        updateTotal = .zero
        updateLongest = .zero
    }

    /// "yes" when a window of the app is at least partly visible ("no" means occluded or
    /// minimized: AppKit then skips drawing and App Nap may throttle the process).
    private static func visibility() -> String {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) } ? "yes" : "no"
    }

    private func write(_ line: String) {
        output.write(Data((line + "\n").utf8))
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    /// Resident set size, as `ps -o rss` reports it.
    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
