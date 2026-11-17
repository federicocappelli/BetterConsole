import BCModel
import BCTransport
import CoreFoundation
import Foundation
import Synchronization

/// Lists physical iOS devices reachable over USB or the network (Wi-Fi sync), one per UDID,
/// driven by MobileDevice notifications.
/// If the framework cannot be loaded, emits `[]` once and stays open.
public struct MobileDeviceDiscovery: DeviceDiscovery {
    private let source: (any DeviceListSource)?

    public init() {
        self.init(source: MobileDeviceMonitor.shared)
    }

    init(source: (any DeviceListSource)?) {
        self.source = source
    }

    public func devices() -> AsyncStream<[LogDevice]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [LogDevice].self)
        guard let source else {
            continuation.yield([])
            return stream
        }
        let token = source.subscribe { continuation.yield($0) }
        continuation.onTermination = { _ in source.unsubscribe(token) }
        return stream
    }
}

/// Publishes the current device list to subscribers. `subscribe` delivers the current list
/// immediately, then every change, in order.
protocol DeviceListSource: Sendable {
    func subscribe(_ onChange: @escaping @Sendable ([LogDevice]) -> Void) -> Int
    func unsubscribe(_ token: Int)
}

// MARK: - Device info and roster

struct DeviceInfo: Sendable, Equatable {
    let name: String
    let productType: String?
    let productVersion: String?

    /// Marketing names for product types; unknown types are shown raw.
    static func marketingName(_ productType: String) -> String {
        marketingNames[productType] ?? productType
    }

    private static let marketingNames: [String: String] = [
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air",
        "iPhone19,2": "iPhone 18 Pro",
    ]

    func logDevice(udid: String, connection: LogDevice.Connection) -> LogDevice {
        LogDevice(
            id: udid,
            name: name,
            kind: .physical,
            model: productType.map(Self.marketingName),
            osVersion: productVersion.map { "iOS \($0)" },
            connection: connection)
    }
}

/// Which devices are attached on which interfaces, plus what is known about each. Pure value
/// logic, so the attach/detach/replug rules are testable without hardware.
///
/// The same phone is often reported on USB and network at once: it is listed once, as `.usb`
/// while on USB (streams prefer it), else `.wifi`, and only removed once gone from both. A
/// device is listed once its name is known (over Wi-Fi only, its real name: the fallback is
/// for USB); info is remembered across unplug and replug.
struct DeviceRoster {
    private var interfaces: [String: Set<DeviceInterface>] = [:]
    private var info: [String: DeviceInfo] = [:]
    /// Devices listed under a fallback name because their info could not be read; it is
    /// re-read on the next attach instead of being kept for the process lifetime.
    private var provisional: Set<String> = []

    /// Returns true if the listed devices may have changed.
    mutating func attached(udid: String, interface: DeviceInterface) -> Bool {
        interfaces[udid, default: []].insert(interface).inserted
    }

    mutating func detached(udid: String, interface: DeviceInterface) -> Bool {
        guard interfaces[udid]?.remove(interface) != nil else { return false }
        if interfaces[udid]?.isEmpty == true { interfaces[udid] = nil }
        return true
    }

    /// A provisional (fallback) name is ignored once real info is known: a slow USB read can
    /// finish after a Wi-Fi read or stream open stored the real name.
    mutating func setInfo(_ info: DeviceInfo, for udid: String, provisional: Bool = false) -> Bool {
        if provisional, hasInfo(udid) { return false }
        if provisional { self.provisional.insert(udid) } else { self.provisional.remove(udid) }
        guard self.info[udid] != info else { return false }
        self.info[udid] = info
        return true
    }

    func interfaces(of udid: String) -> Set<DeviceInterface> { interfaces[udid] ?? [] }

    /// The stored info and whether it is the provisional fallback.
    func storedInfo(_ udid: String) -> (info: DeviceInfo, provisional: Bool)? {
        info[udid].map { ($0, provisional.contains(udid)) }
    }

    /// True once real (not fallback) info is known.
    func hasInfo(_ udid: String) -> Bool { info[udid] != nil && !provisional.contains(udid) }

    var devices: [LogDevice] {
        interfaces
            .compactMap { udid, interfaces -> LogDevice? in
                let connection: LogDevice.Connection
                if interfaces.contains(.usb) {
                    connection = .usb
                } else if interfaces.contains(.network), !provisional.contains(udid) {
                    // Wi-Fi only: listed under its real name, never the fallback.
                    connection = .wifi
                } else {
                    return nil
                }
                return info[udid]?.logDevice(udid: udid, connection: connection)
            }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

// MARK: - Monitor

/// The process-wide MobileDevice notification subscription. Owns a retained `AMDeviceRef` per
/// attached (udid, interface) and publishes the device list (USB and network).
///
/// Threads: notifications arrive on a dedicated thread running its own run loop (the
/// subscription is made there). Device info is read by `DeviceInfoLoader` on its own queues,
/// since reading it connects to the device and blocks. All mutable state is behind one
/// `Mutex`; subscribers are called while it is held, so they observe changes in order (they
/// only yield to a stream).
final class MobileDeviceMonitor: DeviceListSource, DeviceInfoSource {
    static let shared: MobileDeviceMonitor? = MobileDeviceAPI.load().map(MobileDeviceMonitor.init)

    private struct Key: Hashable {
        let udid: String
        let interface: DeviceInterface
    }

    private struct State {
        var roster = DeviceRoster()
        var refs: [Key: OpaqueRef] = [:]
        var subscribers: [Int: @Sendable ([LogDevice]) -> Void] = [:]
        var nextToken = 0
        var published: [LogDevice] = []
    }

    private static let messageConnected: UInt32 = 1
    private static let messageDisconnected: UInt32 = 2
    let api: MobileDeviceAPI
    private let state = Mutex(State())
    private let infoLoader = DeviceInfoLoader()

    private init(api: MobileDeviceAPI) {
        self.api = api
        let thread = Thread { [self] in runNotificationLoop() }
        thread.name = "BCMobileDevice.notifications"
        thread.qualityOfService = .utility
        thread.start()
    }

    // MARK: DeviceListSource

    func subscribe(_ onChange: @escaping @Sendable ([LogDevice]) -> Void) -> Int {
        state.withLock { state in
            let token = state.nextToken
            state.nextToken += 1
            state.subscribers[token] = onChange
            onChange(state.published)
            return token
        }
    }

    func unsubscribe(_ token: Int) {
        state.withLock { _ = $0.subscribers.removeValue(forKey: token) }
    }

    /// A +1 retained `AMDeviceRef` for `udid` on `interface`; the caller must `deviceRelease` it.
    func retainedDevice(udid: String, interface: DeviceInterface) -> OpaqueRef? {
        state.withLock { state in
            guard let ref = state.refs[Key(udid: udid, interface: interface)] else { return nil }
            _ = api.deviceRetain(ref.pointer)
            return ref
        }
    }

    /// The interfaces `udid` is currently attached on.
    func interfaces(of udid: String) -> Set<DeviceInterface> {
        state.withLock { $0.roster.interfaces(of: udid) }
    }

    // MARK: Notifications

    private func runNotificationLoop() {
        // Never pass `NotificationOptionSearchForPairedDevices: true`. Measured on macOS 27.2
        // with fresh bundle ids: with it, the subscription itself triggers the "find devices on
        // local networks" prompt (nehelper alert logged at the same millisecond as "Subscribed
        // for device notifications from usbmuxd"); with empty options, no LocalNetwork check
        // happens at all. Empty options still deliver network (Wi-Fi sync) devices, which are
        // listed and streamed from (see `handle`).
        let options = [:] as CFDictionary
        var notification: UnsafeMutableRawPointer?
        let context = Unmanaged.passUnretained(self).toOpaque()  // `shared` lives forever
        let callback: MobileDeviceAPI.NotificationCallback = { info, context in
            guard let info, let context else { return }
            let monitor = Unmanaged<MobileDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            let device = info.load(as: UnsafeMutableRawPointer.self)
            let message = info.load(fromByteOffset: 8, as: UInt32.self)
            monitor.handle(device: device, message: message)
        }
        let result = MobileDeviceAPI.withPointer(to: options) {
            api.notificationSubscribeWithOptions(callback, 0, 0, context, &notification, $0)
        }
        guard result == 0 else { return }  // stays empty: discovery shows no devices
        // Keep the run loop alive even if MobileDevice schedules nothing on it.
        RunLoop.current.add(Port(), forMode: .default)
        while true { RunLoop.current.run() }
    }

    private func handle(device: UnsafeMutableRawPointer, message: UInt32) {
        // USB and network (Wi-Fi sync) refs are kept, one per (udid, interface); any other
        // interface is ignored before any call that could talk to the device.
        let interface = api.interface(of: device)
        guard message == Self.messageConnected || message == Self.messageDisconnected,
              interface == .usb || interface == .network,
              let udid = api.identifier(of: device)
        else { return }
        let key = Key(udid: udid, interface: interface)
        if message == Self.messageConnected {
            _ = api.deviceRetain(device)
            let needsInfo = state.withLock { state -> Bool in
                if let old = state.refs.updateValue(OpaqueRef(device), forKey: key) {
                    api.deviceRelease(old.pointer)
                }
                // Only a new attach (re)starts reading: a duplicate notification must not reset
                // a running schedule.
                guard state.roster.attached(udid: udid, interface: key.interface) else { return false }
                publish(&state)
                return !state.roster.hasInfo(udid)
            }
            if needsInfo { infoLoader.load(udid: udid, over: interface, from: self) }
        } else {
            state.withLock { state in
                if let old = state.refs.removeValue(forKey: key) { api.deviceRelease(old.pointer) }
                if state.roster.detached(udid: udid, interface: key.interface) { publish(&state) }
            }
        }
    }

    private func publish(_ state: inout State) {
        let devices = state.roster.devices
        guard devices != state.published else { return }
        state.published = devices
        for subscriber in state.subscribers.values { subscriber(devices) }
    }

    // MARK: Device info

    /// A stream opened over `interface`: reads the device's info now if it is still missing.
    func streamOpened(udid: String, over interface: DeviceInterface) {
        infoLoader.streamOpened(udid: udid, over: interface, from: self)
    }

    func readInfo(udid: String, over interface: DeviceInterface) -> DeviceInfo? {
        guard let ref = retainedDevice(udid: udid, interface: interface) else { return nil }
        defer { api.deviceRelease(ref.pointer) }
        return readInfo(ref.pointer)
    }

    func isAttached(udid: String, over interface: DeviceInterface) -> Bool {
        interfaces(of: udid).contains(interface)
    }

    func hasInfo(udid: String) -> Bool {
        state.withLock { $0.roster.hasInfo(udid) }
    }

    func infoLoaded(_ info: DeviceInfo, udid: String, provisional: Bool) {
        state.withLock { state in
            if state.roster.setInfo(info, for: udid, provisional: provisional) { publish(&state) }
        }
    }

    private func readInfo(_ device: UnsafeMutableRawPointer) -> DeviceInfo? {
        guard api.deviceConnect(device) == 0 else { return nil }
        defer { _ = api.deviceDisconnect(device) }
        var sessionStarted = false
        if api.deviceIsPaired(device) == 1, api.deviceValidatePairing(device) == 0 {
            sessionStarted = api.deviceStartSession(device) == 0
        }
        defer { if sessionStarted { _ = api.deviceStopSession(device) } }
        guard let name = api.copyStringValue(device, key: "DeviceName") else { return nil }
        return DeviceInfo(
            name: name,
            productType: api.copyStringValue(device, key: "ProductType"),
            productVersion: api.copyStringValue(device, key: "ProductVersion"))
    }
}
