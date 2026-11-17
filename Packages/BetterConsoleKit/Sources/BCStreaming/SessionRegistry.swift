import Foundation
import Observation
import BCModel
import BCStore
import BCTransport

/// Merges device discoveries with known sessions (spec §6.6): a row exists while its device is
/// discovered or its session still holds logs. Handles disconnect and auto-resume.
@MainActor
@Observable
public final class SessionRegistry {
    public struct Row: Identifiable, Equatable, Sendable {
        public let device: LogDevice
        public let isAvailable: Bool
        public var id: LogDevice.ID { device.id }
    }

    /// Sorted: this Mac, physical devices by name, simulators by name.
    public var rows: [Row] {
        var result: [Row] = present.values.map { Row(device: $0, isAvailable: true) }
        for (id, session) in sessions where present[id] == nil {
            // Reading `revision` makes the row observable across clear().
            _ = session.revision
            if session.store.count > 0 { result.append(Row(device: session.device, isAvailable: false)) }
        }
        return result.sorted(by: Self.order)
    }

    /// Called once for each new session, right after it is created and before it can start
    /// (for example to restore the device's saved filter).
    @ObservationIgnored public var onSessionCreated: (@MainActor (StreamSession) -> Void)?

    @ObservationIgnored private let discoveries: [any DeviceDiscovery]
    @ObservationIgnored private let transports: [any LogTransport]
    @ObservationIgnored private let budget: MemoryBudget
    @ObservationIgnored private let drainInterval: Duration

    /// Latest list from each discovery, by index.
    @ObservationIgnored private var latest: [Int: [LogDevice]] = [:]
    private var present: [LogDevice.ID: LogDevice] = [:]
    private var sessions: [LogDevice.ID: StreamSession] = [:]
    /// Opened files' sessions: looked up like devices' sessions, but never rows, and left
    /// alone by discovery updates.
    @ObservationIgnored private var fileSessions: [LogDevice.ID: StreamSession] = [:]

    public init(
        discoveries: [any DeviceDiscovery], transports: [any LogTransport], budget: MemoryBudget,
        drainInterval: Duration = .milliseconds(100)
    ) {
        self.discoveries = discoveries
        self.transports = transports
        self.budget = budget
        self.drainInterval = drainInterval
    }

    /// The session for a discovered device or a known disconnected one. A pure lookup: sessions
    /// are created when a discovery reports their device, so this is safe to call from a view body.
    public func session(for id: LogDevice.ID) -> StreamSession? {
        sessions[id] ?? fileSessions[id]
    }

    /// The session of an opened file (`device.kind == .file`), created with `transport` on the
    /// first call (and handed to `onSessionCreated`, so it starts with the file's filter); the
    /// same session while it stays open. Not started.
    public func openFileSession(device: LogDevice, transport: any LogTransport) -> StreamSession {
        if let existing = fileSessions[device.id] { return existing }
        let session = StreamSession(
            device: device, transport: transport, budget: budget, drainInterval: drainInterval)
        fileSessions[device.id] = session
        onSessionCreated?(session)
        return session
    }

    /// Forgets an opened file's session (its window closed); the session is released once
    /// nothing else holds it, giving its memory back to the budget.
    public func closeFileSession(id: LogDevice.ID) {
        fileSessions[id] = nil
    }

    /// The sidebar selection to keep: `selection` while it still has a row, otherwise this
    /// Mac. A session can outlive its row (cleared while disconnected, or disconnected while
    /// streaming with no logs), so `session(for:)` alone is not enough. `nil` stays `nil`.
    public func validSelection(_ selection: LogDevice.ID?) -> LogDevice.ID? {
        guard let selection else { return nil }
        return rows.contains { $0.id == selection } ? selection : Self.localDeviceID
    }

    /// This Mac's device ID (see `LocalMacDiscovery`).
    public static let localDeviceID: LogDevice.ID = "local"

    /// IDs of every session the registry holds (for tests).
    var sessionIDs: [LogDevice.ID] { Array(sessions.keys) }

    /// Consumes every discovery until cancelled.
    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            for (index, discovery) in discoveries.enumerated() {
                let updates = discovery.devices()
                group.addTask { [weak self] in
                    for await devices in updates {
                        guard let self else { return }
                        await self.apply(devices, from: index)
                    }
                }
            }
        }
    }

    private func apply(_ devices: [LogDevice], from index: Int) {
        latest[index] = devices
        var merged: [LogDevice.ID: LogDevice] = [:]
        for i in latest.keys.sorted() {
            for device in latest[i] ?? [] where merged[device.id] == nil {
                merged[device.id] = device
            }
        }
        present = merged

        for (id, device) in merged where sessions[id] == nil {
            let session = StreamSession(
                device: device, transport: transports.first { $0.supports(device) },
                budget: budget, drainInterval: drainInterval)
            sessions[id] = session
            onSessionCreated?(session)
        }

        for (id, device) in merged { sessions[id]?.deviceUpdated(device) }

        // This discovery has seen these devices since any earlier failure.
        for device in devices { sessions[device.id]?.failedSinceDeviceSeen = false }

        for (id, session) in sessions {
            if merged[id] == nil {
                guard !session.isDisconnected else { continue }
                session.deviceDisappeared()
                // Nothing to browse and nothing to resume: forget it. A session that was
                // streaming stays (its row is hidden while empty) so it can auto-resume.
                if session.store.count == 0, session.state == .disconnected(wasStreaming: false) {
                    sessions[id] = nil
                }
            } else if session.isDisconnected {
                session.deviceReappeared()
            }
        }
    }

    private static func order(_ a: Row, _ b: Row) -> Bool {
        func rank(_ kind: LogDevice.Kind) -> Int {
            switch kind {
            case .thisMac: 0
            case .physical: 1
            case .simulator: 2
            case .file: 3
            }
        }
        let (ra, rb) = (rank(a.device.kind), rank(b.device.kind))
        if ra != rb { return ra < rb }
        switch a.device.name.localizedStandardCompare(b.device.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.device.id < b.device.id
        }
    }
}

extension SessionRegistry {
    /// Runs `handler` for each new session after whatever `onSessionCreated` already does
    /// (`connect(registry:workspace:)` sets the session's filter there), keeping both.
    public func addSessionCreatedHandler(_ handler: @escaping @MainActor (StreamSession) -> Void) {
        let previous = onSessionCreated
        onSessionCreated = { session in
            previous?(session)
            handler(session)
        }
    }
}
