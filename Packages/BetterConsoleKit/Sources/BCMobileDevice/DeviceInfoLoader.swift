import Foundation
import Synchronization

/// Where `DeviceInfoLoader` reads device info and delivers it (the monitor; faked in tests).
protocol DeviceInfoSource: Sendable {
    /// Connects over `interface` and reads name, product type and version. Blocks.
    func readInfo(udid: String, over interface: DeviceInterface) -> DeviceInfo?
    func isAttached(udid: String, over interface: DeviceInterface) -> Bool
    /// True once real (not fallback) info is known.
    func hasInfo(udid: String) -> Bool
    /// Stores `info`. A provisional (fallback) `info` must be ignored when real info is
    /// already known, decided atomically with the store.
    func infoLoaded(_ info: DeviceInfo, udid: String, provisional: Bool)
}

/// Schedules device info reads, one loop per (udid, interface).
///
/// USB reads retry quickly a few times (right after plug-in lockdown may not answer yet), then
/// fall back to a generic, provisional name. Network reads can take long or fail for a long
/// time (an asleep phone), so they run on their own queue (a USB device plugged in meanwhile
/// never waits behind them), retry with backoff for as long as the device stays on the
/// network, and never fall back: a Wi-Fi-only device is listed once its real name is known.
final class DeviceInfoLoader: Sendable {
    struct Policy: Sendable {
        var usbAttempts: Int
        var usbDelay: Duration
        /// Delays after the first failed network reads, in order; then `networkRepeat`.
        var networkBackoff: [Duration]
        var networkRepeat: Duration

        static let standard = Policy(
            usbAttempts: 5, usbDelay: .seconds(1),
            networkBackoff: [.seconds(5), .seconds(30)], networkRepeat: .seconds(300))

        /// The wait before the next network read after `count` failed ones (1-based).
        func networkDelay(afterFailedRead count: Int) -> Duration {
            count - 1 < networkBackoff.count ? networkBackoff[max(count - 1, 0)] : networkRepeat
        }
    }

    static let fallback = DeviceInfo(name: "iOS Device", productType: nil, productVersion: nil)

    private struct Key: Hashable {
        let udid: String
        let interface: DeviceInterface
    }

    private let policy: Policy
    private let usbQueue = DispatchQueue(label: "BCMobileDevice.deviceInfo.usb", qos: .utility)
    private let networkQueue = DispatchQueue(label: "BCMobileDevice.deviceInfo.network", qos: .utility)
    /// The current schedule's generation per running (udid, interface). `load` starts a new
    /// one; ticks of an older schedule find their generation stale and stop.
    private let running = Mutex<[Key: Int]>([:])

    init(policy: Policy = .standard) {
        self.policy = policy
    }

    /// Starts reading `udid`'s info over `interface` now, replacing any schedule already
    /// running for it (a device that left and came back is read at once, not after the backoff
    /// planned before it left).
    func load(udid: String, over interface: DeviceInterface, from source: any DeviceInfoSource) {
        let key = Key(udid: udid, interface: interface)
        let generation = running.withLock { running in
            let next = (running[key] ?? 0) + 1
            running[key] = next
            return next
        }
        schedule(key, generation: generation, attempt: 1, after: nil, source: source)
    }

    /// A stream just opened over `interface`, so the device answers now: if its info is still
    /// missing, read it once at once rather than waiting for the backoff.
    func streamOpened(udid: String, over interface: DeviceInterface, from source: any DeviceInfoSource) {
        guard !source.hasInfo(udid: udid) else { return }
        queue(for: interface).async {
            guard !source.hasInfo(udid: udid), let info = source.readInfo(udid: udid, over: interface) else { return }
            source.infoLoaded(info, udid: udid, provisional: false)
        }
    }

    private func queue(for interface: DeviceInterface) -> DispatchQueue {
        interface == .usb ? usbQueue : networkQueue
    }

    private func schedule(
        _ key: Key, generation: Int, attempt: Int, after delay: Duration?, source: any DeviceInfoSource
    ) {
        let work: @Sendable () -> Void = { [self] in run(key, generation: generation, attempt: attempt, source: source) }
        if let delay {
            queue(for: key.interface).asyncAfter(deadline: .now() + Self.dispatchInterval(delay), execute: work)
        } else {
            queue(for: key.interface).async(execute: work)
        }
    }

    private func isCurrent(_ key: Key, _ generation: Int) -> Bool {
        running.withLock { $0[key] == generation }
    }

    private func run(_ key: Key, generation: Int, attempt: Int, source: any DeviceInfoSource) {
        guard isCurrent(key, generation) else { return }  // replaced by a newer schedule
        let finish = { self.finish(key, generation) }
        guard source.isAttached(udid: key.udid, over: key.interface), !source.hasInfo(udid: key.udid) else {
            finish()
            return
        }
        if let info = source.readInfo(udid: key.udid, over: key.interface) {
            finish()
            source.infoLoaded(info, udid: key.udid, provisional: false)
            return
        }
        switch key.interface {
        case .usb:
            if attempt < policy.usbAttempts {
                schedule(key, generation: generation, attempt: attempt + 1, after: policy.usbDelay, source: source)
            } else {
                finish()
                // The source ignores this if real info arrived meanwhile (decided under its lock).
                source.infoLoaded(Self.fallback, udid: key.udid, provisional: true)
            }
        default:
            schedule(
                key, generation: generation, attempt: attempt + 1,
                after: policy.networkDelay(afterFailedRead: attempt), source: source)
        }
    }

    private func finish(_ key: Key, _ generation: Int) {
        running.withLock { if $0[key] == generation { $0[key] = nil } }
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
