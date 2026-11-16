import Foundation
import Observation
import Synchronization
import BCFilter
import BCModel
import BCStore
import BCTransport

/// One device's log stream and store (spec §6.6). The transport is consumed off-main into a
/// `BoundedBatchQueue` as it arrives, so a slow consumer drops and counts instead of buffering
/// (MVP spec §6.5.1); a main-actor loop drains the queue into `store` every `drainInterval`.
/// With a filter set, `rows` lists only the matching entries (spec §8): an off-main checker
/// gives queued batches their verdicts (again after each filter change) and the drain only
/// takes checked batches, so it never runs the filter on main; stored entries are rescanned in
/// the background on each change.
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
    /// What the log table shows: every stored entry, or only those matching `filter`.
    public let rows: LogRows
    public private(set) var filter: FilterExpression?
    /// True while stored entries are being rescanned for a new filter.
    public private(set) var isFiltering = false
    /// Share of the rescan done, 0...1.
    public private(set) var filterProgress: Double = 0
    /// Distinct field values seen in drained entries, for filter suggestions.
    @ObservationIgnored public private(set) var seenValues = SeenValues()
    /// Entries dropped by the bounded queue since the last `clear()`.
    public private(set) var droppedCount = 0
    /// Bumps on every drain that appended entries, on `clear()`, whenever the memory budget
    /// evicts entries from `store`, and whenever `rows` changes (filter change, rescan step).
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
    /// Most entries applied per drain tick, so one tick after a main-thread stall stays cheap.
    static let maxEntriesPerDrain = 20_000

    // One generation per started stream. A consumer only reports back while its generation is
    // current, so streams the session cancelled (pause, disconnect, restart) never fail it.
    @ObservationIgnored private var generation = 0
    /// Lives as long as the session: entries a stopped stream left unchecked are still
    /// checked and drained after it stops.
    @ObservationIgnored let queue: BoundedBatchQueue
    /// The running stream's way into `queue`; closed when the session stops the stream.
    @ObservationIgnored private var inlet: StreamInlet?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var checker: Task<Void, Never>?
    /// Runs while streaming and afterwards until the queue is empty.
    @ObservationIgnored private var drainLoop: Task<Void, Never>?
    /// Held while streaming. Without it App Nap throttles a hidden or covered app: decoding
    /// fell from ~20k to ~7k msgs/s and the drain from 10 to ~4 updates/s (Task 11).
    @ObservationIgnored private var appNapActivity: (any NSObjectProtocol)?
    var isPreventingAppNap: Bool { appNapActivity != nil }
    /// Set when the stream fails; cleared by the registry when the device is next reported
    /// present. A disappearance while set means the failure was the disconnect itself.
    @ObservationIgnored var failedSinceDeviceSeen = false

    // MARK: Filtering state
    @ObservationIgnored let filterSlot = FilterSlot()
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    /// Rescan tasks not yet finished, cancelled ones included (for tests).
    @ObservationIgnored private(set) var runningRescans = 0
    /// Largest rescan chunk; the chunk shrinks below it while copying one takes over 4 ms.
    @ObservationIgnored var maxRescanChunk = 10_000
    @ObservationIgnored private var rescanChunk = 10_000
    /// Called after each rescan or match-count chunk is copied from the store, before it is
    /// evaluated (tests).
    @ObservationIgnored var afterRescanCopy: (() -> Void)?
    /// The match count's chunk size, kept from one count to the next (the editor recounts
    /// every 2 s), adapted as the rescan's is.
    @ObservationIgnored private var countChunk = 10_000
    /// Used instead of the measured time of each chunk copy (tests).
    @ObservationIgnored var copyDurationOverride: Duration?
    /// Holds the off-main checker while closed (tests).
    @ObservationIgnored let checkerGate = CheckerGate()
    static let rescanCopyBudget = Duration.milliseconds(4)
    static let minRescanChunk = 500

    public init(
        device: LogDevice, transport: (any LogTransport)?, budget: MemoryBudget,
        drainInterval: Duration = .milliseconds(100), queueCapacity: Int = 200_000
    ) {
        self.device = device
        self.transport = transport
        self.budget = budget
        self.drainInterval = drainInterval
        queue = BoundedBatchQueue(capacity: queueCapacity)
        let store = RingBufferLogStore()
        self.store = store
        rows = LogRows(store: store)
        budget.register(store) { [weak self] in
            guard let self else { return }
            rows.dropEvicted()
            revision += 1
        }
        checker = Task.detached(priority: .userInitiated) { [queue, filterSlot, checkerGate] in
            await Self.runChecker(queue: queue, slot: filterSlot, gate: checkerGate)
        }
    }

    isolated deinit {
        rescanTask?.cancel()
        checker?.cancel()
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

    /// Empties the store and resets `droppedCount`; the state and filter are unchanged. A
    /// running rescan finds nothing left to add.
    public func clear() {
        queue.removeAll()
        store.removeAll()
        rows.clear()
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
        let inlet = StreamInlet(queue: queue)
        self.inlet = inlet
        state = .streaming
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Streaming logs")

        let stream = transport.stream(from: device)
        consumer = Task.detached { [weak self] in
            var reason: String?
            do {
                // Unchecked and at once: checking here would let a slow filter back batches up
                // in the transport's unbounded buffer, uncounted.
                for try await entries in stream { inlet.push(entries) }
                reason = "The log stream ended unexpectedly."
            } catch {
                reason = String(describing: error)
            }
            if Task.isCancelled { return }
            await self?.streamEnded(generation: gen, reason: reason ?? "")
        }

        startDrainLoop()
    }

    private func startDrainLoop() {
        guard drainLoop == nil else { return }
        let interval = drainInterval
        drainLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.drain(max: Self.maxEntriesPerDrain)
                if self.state != .streaming, self.queue.count == 0 {
                    self.drainLoop = nil
                    return
                }
            }
        }
    }

    /// Cancels the stream, keeping everything already received: what is checked (or, with no
    /// filter, everything) is drained now, the rest by the drain loop once checked.
    private func stop() {
        generation += 1
        inlet?.close()  // late pushes from the cancelled consumer go nowhere
        inlet = nil
        consumer?.cancel()
        consumer = nil
        drain(max: .max)
        if queue.count == 0 {
            drainLoop?.cancel()
            drainLoop = nil
        }
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

    /// Appends up to `max` queued entries to the store. With a filter set, only batches the
    /// checker has judged against the current filter are taken (the rest wait in the queue),
    /// so the filter itself never runs here.
    private func drain(max: Int) {
        let (filterGeneration, filter) = filterSlot.current()
        let filtered = filter != nil && rows.isFiltered
        var (batches, dropped) = queue.drain(
            max: max, checkedAgainst: filtered ? filterGeneration : nil)
        if dropped > 0 { droppedCount += dropped }
        guard !batches.isEmpty else { return }
        var position = store.removedCount + store.count
        for b in batches.indices {
            // Each stream's decoder numbers from 1; re-stamp so ids increase across streams. In
            // place: copying every entry here was a visible share of the main thread at 20k/s.
            let firstID = nextEntryID
            nextEntryID += UInt64(batches[b].entries.count)
            for i in batches[b].entries.indices {
                batches[b].entries[i].setID(firstID + UInt64(i))
                seenValues.insert(batches[b].entries[i])
            }
            if filtered, let matches = batches[b].matches {
                for i in matches.indices where matches[i] { rows.appendLive(position + i) }
            }
            position += batches[b].entries.count
            store.append(contentsOf: batches[b].entries)
        }
        revision += 1
        budget.enforce()
    }

    // MARK: Filtering

    /// Shows only entries matching `expression` (nil: everything). Stored entries are rescanned
    /// in the background, newest first; a newer change cancels the running rescan.
    public func setFilter(_ expression: FilterExpression?) {
        guard expression != filter else { return }
        filter = expression
        rescanTask?.cancel()
        rescanTask = nil
        let compiled = CompiledFilter(expression)
        guard !compiled.matchesEverything else {
            filterSlot.set(nil)
            rows.installUnfiltered()
            queue.wake()
            revision += 1
            isFiltering = false
            filterProgress = 1
            return
        }
        revision += 1
        let filterGeneration = filterSlot.set(compiled)
        queue.wake()  // queued verdicts are stale: check them against this filter
        rows.installFiltered(MatchIndex())
        let low = store.removedCount
        let boundary = low + store.count  // entries from here on are indexed by the drain
        guard boundary > low else {
            isFiltering = false
            filterProgress = 1
            return
        }
        isFiltering = true
        filterProgress = 0
        rescanChunk = maxRescanChunk
        runningRescans += 1
        rescanTask = Task { [weak self] in
            defer { self?.runningRescans -= 1 }
            var cursor = boundary  // positions below it are still to scan
            while true {
                guard !Task.isCancelled,
                      let chunk = self?.takeRescanChunk(below: &cursor, generation: filterGeneration)
                else { return }
                guard let matches = await Self.evaluate(chunk, filter: compiled),
                      !Task.isCancelled, let self
                else { return }
                self.publishRescan(
                    matches, generation: filterGeneration,
                    progress: Double(boundary - cursor) / Double(boundary - low))
            }
        }
    }

    /// How many stored entries `expression` (already resolved: no links) matches, for the
    /// editor's preview (ES §8.5); nil once the calling task is cancelled. Counted like the
    /// rescan: newest first, chunks copied on main (each copy under 4 ms) and checked off main,
    /// with a cancellation check before every entry when the filter has a regex. The chunk
    /// size adapts as the rescan's does and carries over to the next count. Leaves `filter`
    /// and `rows` alone, and can run alongside a rescan.
    ///
    /// `total` is the number of entries counted: those stored when the count starts, minus any
    /// evicted (or cleared) before their chunk is copied. A chunk once copied stays counted
    /// even if it is evicted while being checked. Entries arriving during the count are not
    /// included. With no filter (or one matching everything) both are the stored count.
    public func countMatches(_ expression: FilterExpression?) async -> MatchCount? {
        guard !Task.isCancelled else { return nil }
        let compiled = CompiledFilter(expression)
        guard !compiled.matchesEverything else {
            return MatchCount(matched: store.count, total: store.count)
        }
        var cursor = store.removedCount + store.count
        var size = Swift.min(countChunk, maxRescanChunk)
        var counted = MatchCount(matched: 0, total: 0)
        while let chunk = copyChunk(below: &cursor, size: &size) {
            countChunk = size
            guard let matches = await Self.evaluate(chunk, filter: compiled), !Task.isCancelled
            else { return nil }
            counted.matched += matches.count
            counted.total += chunk.entries.count
        }
        return counted
    }

    /// Off-main, for the session's lifetime: gives queued batches their verdicts against the
    /// current filter, oldest first, and again whenever the filter changes. Idle without a
    /// filter (the drain then takes batches unchecked). A batch whose filter changes mid-check
    /// is abandoned and checked again; with a regex that is noticed at the next entry.
    nonisolated private static func runChecker(
        queue: BoundedBatchQueue, slot: FilterSlot, gate: CheckerGate
    ) async {
        var wakeups = queue.wakeups.makeAsyncIterator()
        while !Task.isCancelled {
            let (generation, filter) = slot.current()
            if let filter, let job = queue.nextToCheck(against: generation) {
                let checkEvery = filter.containsRegex ? 1 : 1_000
                var matches: [Bool] = []
                matches.reserveCapacity(job.entries.count)
                var sinceCheck = 0
                var stale = false
                for entry in job.entries {
                    sinceCheck += 1
                    if sinceCheck == checkEvery {
                        sinceCheck = 0
                        if Task.isCancelled || slot.current().0 != generation {
                            stale = true
                            break
                        }
                    }
                    gate.pass()
                    matches.append(filter.matches(entry))
                }
                if !stale {
                    queue.completeCheck(id: job.id, matches: matches, generation: generation)
                }
                continue
            }
            guard await wakeups.next() != nil else { return }
        }
    }

    /// Main-actor step of the rescan: the next chunk below `cursor`, or nil (ending the
    /// rescan) once the filter changed or nothing is left above the evicted part.
    private func takeRescanChunk(
        below cursor: inout Int, generation: UInt64
    ) -> (entries: [LogEntry], firstPosition: Int)? {
        guard filterSlot.current().0 == generation else { return nil }
        guard let chunk = copyChunk(below: &cursor, size: &rescanChunk) else {
            isFiltering = false
            filterProgress = 1
            rescanTask = nil
            return nil
        }
        return chunk
    }

    /// Main-actor step shared by the rescan and the match count: copies up to `size` stored
    /// entries below `cursor` (newest first) and moves the cursor down. `size` halves (down to
    /// `minRescanChunk`) while a copy takes over 4 ms and doubles (up to `maxRescanChunk`)
    /// while it is quick. Nil when nothing is left above the evicted part.
    private func copyChunk(
        below cursor: inout Int, size: inout Int
    ) -> (entries: [LogEntry], firstPosition: Int)? {
        let removed = store.removedCount
        guard cursor > removed else { return nil }
        let first = Swift.max(removed, cursor - size)
        let clock = ContinuousClock()
        let started = clock.now
        var entries: [LogEntry] = []
        entries.reserveCapacity(cursor - first)
        for p in first..<cursor { entries.append(store[p - removed]) }
        let elapsed = copyDurationOverride ?? (clock.now - started)
        if elapsed > Self.rescanCopyBudget {
            size = Swift.max(Self.minRescanChunk, size / 2)
        } else if elapsed < Self.rescanCopyBudget / 4 {
            size = Swift.min(maxRescanChunk, size * 2)
        }
        cursor = first
        afterRescanCopy?()
        return (entries, first)
    }

    /// Off-main: the positions of `chunk`'s matching entries, newest first, or nil once
    /// cancelled. Checks for cancellation before every entry when the filter has a regex
    /// (one entry can take seconds), every 1,000 entries otherwise.
    nonisolated private static func evaluate(
        _ chunk: (entries: [LogEntry], firstPosition: Int), filter: CompiledFilter
    ) async -> [Int]? {
        let checkEvery = filter.containsRegex ? 1 : 1_000
        let work = Task.detached(priority: .userInitiated) { () -> [Int]? in
            var positions: [Int] = []
            var sinceCheck = checkEvery
            for i in chunk.entries.indices.reversed() {
                if sinceCheck == checkEvery {
                    if Task.isCancelled { return nil }
                    sinceCheck = 0
                }
                sinceCheck += 1
                if filter.matches(chunk.entries[i]) { positions.append(chunk.firstPosition + i) }
            }
            return positions
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Main-actor step: adds a chunk's matches below the current rows, minus any the store
    /// evicted (or cleared) while the chunk was being checked.
    private func publishRescan(_ positionsNewestFirst: [Int], generation: UInt64, progress: Double) {
        guard filterSlot.current().0 == generation else { return }
        let removed = store.removedCount
        rows.prependRescan(Array(positionsNewestFirst.prefix { $0 >= removed }))
        filterProgress = progress
        revision += 1
    }
}

/// The editor preview's "Would match `matched` of `total` messages" (ES §8.5).
public struct MatchCount: Sendable, Equatable {
    public var matched: Int
    public var total: Int

    public init(matched: Int, total: Int) {
        self.matched = matched
        self.total = total
    }
}

/// A stream's way into the session's queue. Closing it, under its lock, guarantees no push
/// from that stream lands afterwards, even one already past the stream's last check.
private final class StreamInlet: Sendable {
    private let queue: BoundedBatchQueue
    private let isOpen = Mutex(true)

    init(queue: BoundedBatchQueue) { self.queue = queue }

    func push(_ entries: [LogEntry]) {
        isOpen.withLock { open in
            if open { queue.push(TaggedBatch(unchecked: entries)) }
        }
    }

    func close() { isOpen.withLock { $0 = false } }
}

/// A test hook in the off-main checker: while closed, the checker waits before checking its
/// next entry, so a test can keep it behind (inside a batch) for exactly as long as it needs.
/// Open, it costs one atomic load per entry.
final class CheckerGate: Sendable {
    private let closed = Atomic<Bool>(false)
    private let holding = Atomic<Bool>(false)

    func close() { closed.store(true, ordering: .sequentiallyConsistent) }
    func open() { closed.store(false, ordering: .sequentiallyConsistent) }

    /// The checker is waiting at the gate.
    var isHolding: Bool { holding.load(ordering: .sequentiallyConsistent) }

    /// Called by the checker before each entry; returns once the gate is open.
    func pass() {
        guard closed.load(ordering: .acquiring) else { return }
        holding.store(true, ordering: .sequentiallyConsistent)
        while closed.load(ordering: .sequentiallyConsistent) { usleep(1_000) }
        holding.store(false, ordering: .sequentiallyConsistent)
    }
}
