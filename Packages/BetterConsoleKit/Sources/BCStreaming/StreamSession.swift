import Foundation
import Observation
import BCModel
import BCStore
import BCTransport

/// One device's log stream and store (spec §6.6). The transport is consumed off-main into a
/// `BoundedBatchQueue`; a main-actor loop drains the queue into `store` every `drainInterval`.
@MainActor
@Observable
public final class StreamSession {
    public enum State: Equatable, Sendable {
        case idle
        case streaming
        case paused
        /// The device is gone. `wasStreaming` sessions restart when it returns.
        case disconnected(wasStreaming: Bool)
        case failed(String)
    }

    public let device: LogDevice
    public private(set) var state: State = .idle
    public let store: LogStore
    /// Entries dropped by the bounded queue since the last `clear()`.
    public private(set) var droppedCount = 0
    /// Bumps on every drain that appended entries, on `clear()`, and whenever the memory budget
    /// evicts entries from `store`.
    public private(set) var revision = 0
    /// Id given to the next stored entry. Never reset (not by pause, start, retry, auto-resume
    /// or `clear()`), so ids are unique and increasing for the session's lifetime.
    @ObservationIgnored private var nextEntryID: UInt64 = 1
    /// Entries appended to the store since the session was created (not reset by `clear()`;
    /// not observed). For throughput diagnostics.
    public var appendedCount: Int { Int(nextEntryID - 1) }

    @ObservationIgnored private let transport: (any LogTransport)?
    @ObservationIgnored private let budget: MemoryBudget
    @ObservationIgnored private let drainInterval: Duration
    @ObservationIgnored private let queueCapacity: Int
    /// Most entries applied per drain tick, so one tick after a main-thread stall stays cheap.
    static let maxEntriesPerDrain = 20_000

    // One generation per started stream. A consumer only reports back while its generation is
    // current, so streams the session cancelled (pause, disconnect, restart) never fail it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var queue: BoundedBatchQueue?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var drainLoop: Task<Void, Never>?
    /// Held while streaming. Without it App Nap throttles a hidden or covered app: decoding
    /// fell from ~20k to ~7k msgs/s and the drain from 10 to ~4 updates/s (Task 11).
    @ObservationIgnored private var appNapActivity: (any NSObjectProtocol)?
    var isPreventingAppNap: Bool { appNapActivity != nil }
    /// Set when the stream fails; cleared by the registry when the device is next reported
    /// present. A disappearance while set means the failure was the disconnect itself.
    @ObservationIgnored var failedSinceDeviceSeen = false

    public init(
        device: LogDevice, transport: (any LogTransport)?, budget: MemoryBudget,
        drainInterval: Duration = .milliseconds(100), queueCapacity: Int = 200_000
    ) {
        self.device = device
        self.transport = transport
        self.budget = budget
        self.drainInterval = drainInterval
        self.queueCapacity = queueCapacity
        let store = RingBufferLogStore()
        self.store = store
        budget.register(store) { [weak self] in self?.revision += 1 }
    }

    isolated deinit {
        consumer?.cancel()
        drainLoop?.cancel()
        if let appNapActivity { ProcessInfo.processInfo.endActivity(appNapActivity) }
        budget.unregister(store)
    }

    // MARK: User actions

    /// Starts streaming from idle, paused or failed; no-op while streaming. While the device is
    /// disconnected, marks the session to start when the device returns.
    public func start() {
        switch state {
        case .idle, .paused, .failed:
            begin()
        case .disconnected:
            state = .disconnected(wasStreaming: true)
        case .streaming:
            break
        }
    }

    /// Stops the stream; received entries stay. While disconnected, cancels the auto-resume.
    public func pause() {
        switch state {
        case .streaming:
            stop()
            state = .paused
        case .disconnected:
            state = .disconnected(wasStreaming: false)
        case .idle, .paused, .failed:
            break
        }
    }

    /// Empties the store and resets `droppedCount`; the state is unchanged.
    public func clear() {
        _ = queue?.drain()
        store.removeAll()
        droppedCount = 0
        revision += 1
    }

    public func retry() {
        if case .failed = state { begin() }
    }

    // MARK: Device presence (driven by SessionRegistry)

    var isDisconnected: Bool {
        if case .disconnected = state { true } else { false }
    }

    func deviceDisappeared() {
        switch state {
        case .streaming:
            stop()
            state = .disconnected(wasStreaming: true)
        case .failed:
            // Disconnect wins over a failure caused by the device vanishing.
            state = .disconnected(wasStreaming: failedSinceDeviceSeen)
        case .idle, .paused:
            state = .disconnected(wasStreaming: false)
        case .disconnected:
            break
        }
        failedSinceDeviceSeen = false
    }

    func deviceReappeared() {
        switch state {
        case .disconnected(wasStreaming: true):
            begin()
        case .disconnected(wasStreaming: false):
            state = .paused
        default:
            break
        }
    }

    // MARK: Streaming

    private func begin() {
        failedSinceDeviceSeen = false
        guard let transport else {
            state = .failed("No transport for this device")
            return
        }
        stop()  // defensive: never two consumers
        generation += 1
        let gen = generation
        let queue = BoundedBatchQueue(capacity: queueCapacity)
        self.queue = queue
        state = .streaming
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Streaming logs")

        let stream = transport.stream(from: device)
        consumer = Task.detached { [weak self] in
            var reason: String?
            do {
                for try await batch in stream { queue.push(batch) }
                reason = "The log stream ended unexpectedly."
            } catch {
                reason = String(describing: error)
            }
            if Task.isCancelled { return }
            await self?.streamEnded(generation: gen, reason: reason ?? "")
        }

        let interval = drainInterval
        drainLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.drain(max: Self.maxEntriesPerDrain)
            }
        }
    }

    /// Cancels the stream and drain loop, keeping everything already received.
    private func stop() {
        generation += 1
        consumer?.cancel()
        consumer = nil
        drainLoop?.cancel()
        drainLoop = nil
        drain(max: .max)  // keep everything already received
        queue = nil  // late pushes from the cancelled consumer go nowhere
        if let appNapActivity {
            ProcessInfo.processInfo.endActivity(appNapActivity)
            self.appNapActivity = nil
        }
    }

    private func streamEnded(generation gen: Int, reason: String) {
        guard gen == generation, state == .streaming else { return }
        stop()
        state = .failed(reason)
        failedSinceDeviceSeen = true
    }

    private func drain(max: Int) {
        guard let queue else { return }
        var (entries, dropped) = queue.drain(max: max)
        if dropped > 0 { droppedCount += dropped }
        guard !entries.isEmpty else { return }
        // Each stream's decoder numbers from 1; re-stamp so ids increase across streams. In
        // place: copying every entry here was a visible share of the main thread at 20k/s.
        let firstID = nextEntryID
        nextEntryID += UInt64(entries.count)
        for i in entries.indices { entries[i].setID(firstID + UInt64(i)) }
        store.append(contentsOf: entries)
        revision += 1
        budget.enforce()
    }
}
