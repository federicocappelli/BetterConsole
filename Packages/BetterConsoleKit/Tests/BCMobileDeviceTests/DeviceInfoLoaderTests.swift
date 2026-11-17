import Foundation
import Synchronization
import Testing
@testable import BCMobileDevice

/// A scripted device-info source: reads per (udid, interface) come from `reads` (nil while
/// the script is empty), optionally blocking on a gate; attachment is set by the test.
final class FakeInfoSource: DeviceInfoSource {
    private struct State {
        var reads: [String: [DeviceInfo?]] = [:]
        var attached: Set<String> = []
        /// Info is stored through a real roster, so its rules (e.g. a provisional name never
        /// replacing a real one) apply as in the monitor.
        var roster = DeviceRoster()
        var readLog: [(udid: String, interface: DeviceInterface)] = []
    }
    private let state = Mutex(State())
    private let gates: [String: DispatchSemaphore]
    /// Runs right after every read returns (an event landing between the loader's read and
    /// its next step).
    let afterRead = Mutex<(@Sendable (String) -> Void)?>(nil)

    init(gates: [String: DispatchSemaphore] = [:]) { self.gates = gates }

    private static func key(_ udid: String, _ interface: DeviceInterface) -> String { "\(udid)/\(interface)" }

    func script(_ udid: String, _ interface: DeviceInterface, _ reads: [DeviceInfo?]) {
        state.withLock { $0.reads[Self.key(udid, interface)] = reads }
    }

    func attach(_ udid: String, _ interface: DeviceInterface) { state.withLock { _ = $0.attached.insert(Self.key(udid, interface)) } }
    func detach(_ udid: String, _ interface: DeviceInterface) { state.withLock { _ = $0.attached.remove(Self.key(udid, interface)) } }

    func readInfo(udid: String, over interface: DeviceInterface) -> DeviceInfo? {
        gates[Self.key(udid, interface)]?.wait()
        defer { afterRead.withLock { $0 }?(udid) }
        return state.withLock { state in
            state.readLog.append((udid, interface))
            let key = Self.key(udid, interface)
            guard var reads = state.reads[key], !reads.isEmpty else { return nil }
            let next = reads.removeFirst()
            state.reads[key] = reads
            return next
        }
    }

    func isAttached(udid: String, over interface: DeviceInterface) -> Bool {
        state.withLock { $0.attached.contains(Self.key(udid, interface)) }
    }

    func hasInfo(udid: String) -> Bool {
        state.withLock { $0.roster.hasInfo(udid) }
    }

    func infoLoaded(_ info: DeviceInfo, udid: String, provisional: Bool) {
        state.withLock { _ = $0.roster.setInfo(info, for: udid, provisional: provisional) }
    }

    func loaded(_ udid: String) -> (info: DeviceInfo, provisional: Bool)? { state.withLock { $0.roster.storedInfo(udid) } }
    func reads(_ udid: String, _ interface: DeviceInterface) -> Int {
        state.withLock { $0.readLog.filter { $0.udid == udid && $0.interface == interface }.count }
    }
}

struct DeviceInfoLoaderTests {
    static let info = DeviceInfo(name: "Test iPhone", productType: "iPhone19,2", productVersion: "27.2.1")
    static let fast = DeviceInfoLoader.Policy(
        usbAttempts: 3, usbDelay: .milliseconds(10),
        networkBackoff: [.milliseconds(10), .milliseconds(20)], networkRepeat: .milliseconds(30))

    /// A Wi-Fi device whose read hangs (asleep) must not hold up a USB device plugged in
    /// meanwhile.
    @Test func blockedNetworkReadDoesNotDelayUSB() async {
        let gate = DispatchSemaphore(value: 0)
        let source = FakeInfoSource(gates: ["wifi-phone/network": gate])
        source.attach("wifi-phone", .network)
        source.attach("usb-phone", .usb)
        source.script("usb-phone", .usb, [Self.info])
        let loader = DeviceInfoLoader(policy: Self.fast)
        loader.load(udid: "wifi-phone", over: .network, from: source)
        loader.load(udid: "usb-phone", over: .usb, from: source)
        #expect(await eventually { source.loaded("usb-phone") != nil })
        #expect(source.loaded("wifi-phone") == nil)
        source.detach("wifi-phone", .network)  // no retry loop left running
        gate.signal()
    }

    /// Network reads retry with backoff while the device stays on the network, and never fall
    /// back to a generic name.
    @Test func networkReadsRetryUntilTheRealInfoArrives() async {
        let source = FakeInfoSource()
        source.attach("p", .network)
        source.script("p", .network, [nil, nil, nil, nil, Self.info])
        let loader = DeviceInfoLoader(policy: Self.fast)
        loader.load(udid: "p", over: .network, from: source)
        #expect(await eventually { source.loaded("p") != nil })
        #expect(source.loaded("p")?.info == Self.info)
        #expect(source.loaded("p")?.provisional == false)
        #expect(source.reads("p", .network) == 5)
    }

    @Test func networkRetriesStopWhenTheDeviceLeaves() async throws {
        let source = FakeInfoSource()
        source.attach("p", .network)
        let loader = DeviceInfoLoader(policy: Self.fast)
        loader.load(udid: "p", over: .network, from: source)
        #expect(await eventually { source.reads("p", .network) >= 2 })
        source.detach("p", .network)
        try await Task.sleep(for: .milliseconds(100))
        let reads = source.reads("p", .network)
        try await Task.sleep(for: .milliseconds(150))
        #expect(source.reads("p", .network) == reads)
        #expect(source.loaded("p") == nil)  // no fallback name for Wi-Fi
    }

    @Test func standardNetworkBackoff() {
        let policy = DeviceInfoLoader.Policy.standard
        #expect(policy.networkDelay(afterFailedRead: 1) == .seconds(5))
        #expect(policy.networkDelay(afterFailedRead: 2) == .seconds(30))
        #expect(policy.networkDelay(afterFailedRead: 3) == .seconds(300))
        #expect(policy.networkDelay(afterFailedRead: 9) == .seconds(300))
    }

    /// USB keeps today's behaviour: a few quick retries, then a provisional generic name.
    @Test func usbFallsBackToAGenericName() async {
        let source = FakeInfoSource()
        source.attach("p", .usb)
        let loader = DeviceInfoLoader(policy: Self.fast)
        loader.load(udid: "p", over: .usb, from: source)
        #expect(await eventually { source.loaded("p") != nil })
        #expect(source.loaded("p")?.info.name == "iOS Device")
        #expect(source.loaded("p")?.provisional == true)
        #expect(source.reads("p", .usb) == 3)
    }

    /// A duplicate request while one is running starts nothing new.
    @Test func duplicateLoadsCoalesce() async throws {
        let gate = DispatchSemaphore(value: 0)
        let source = FakeInfoSource(gates: ["p/network": gate])
        source.attach("p", .network)
        source.script("p", .network, [Self.info])
        let loader = DeviceInfoLoader(policy: Self.fast)
        loader.load(udid: "p", over: .network, from: source)
        loader.load(udid: "p", over: .network, from: source)
        gate.signal()
        #expect(await eventually { source.loaded("p") != nil })
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.reads("p", .network) == 1)
    }

    /// After a Wi-Fi stream opens (so the device answers), info that is still missing is read
    /// again at once instead of waiting out the backoff.
    @Test func streamOpenRereadsMissingInfoOnce() async throws {
        let source = FakeInfoSource()
        source.attach("p", .network)
        let slow = DeviceInfoLoader.Policy(
            usbAttempts: 3, usbDelay: .milliseconds(10), networkBackoff: [.seconds(60)], networkRepeat: .seconds(60))
        let loader = DeviceInfoLoader(policy: slow)
        loader.load(udid: "p", over: .network, from: source)
        #expect(await eventually { source.reads("p", .network) == 1 })
        source.script("p", .network, [Self.info])
        loader.streamOpened(udid: "p", over: .network, from: source)
        #expect(await eventually { source.loaded("p")?.info == Self.info })

        // Info known: nothing to read.
        loader.streamOpened(udid: "p", over: .network, from: source)
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.reads("p", .network) == 2)
    }

    /// The real name arrives (a Wi-Fi read or a stream open) between the last failed USB
    /// read and the fallback being stored: the fallback must not replace it.
    @Test func lateFallbackNeverReplacesTheRealName() async {
        let source = FakeInfoSource()
        source.attach("p", .usb)
        let loader = DeviceInfoLoader(policy: Self.fast)
        source.afterRead.withLock {
            $0 = { udid in
                // The last USB read just failed: the network read lands now.
                if source.reads(udid, .usb) == Self.fast.usbAttempts {
                    source.infoLoaded(Self.info, udid: udid, provisional: false)
                }
            }
        }
        loader.load(udid: "p", over: .usb, from: source)
        #expect(await eventually { source.reads("p", .usb) == Self.fast.usbAttempts })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.loaded("p")?.info == Self.info)
        #expect(source.loaded("p")?.provisional == false)
    }

    /// A Wi-Fi phone that leaves (sleep) and returns gets an immediate read instead of
    /// waiting out the backoff scheduled before it left.
    @Test func returningDeviceIsReadAtOnce() async throws {
        let source = FakeInfoSource()
        let slow = DeviceInfoLoader.Policy(
            usbAttempts: 3, usbDelay: .milliseconds(10), networkBackoff: [.seconds(60)], networkRepeat: .seconds(60))
        let loader = DeviceInfoLoader(policy: slow)
        source.attach("p", .network)
        loader.load(udid: "p", over: .network, from: source)
        #expect(await eventually { source.reads("p", .network) == 1 })  // failed; next in 60 s
        source.detach("p", .network)
        source.script("p", .network, [Self.info])
        source.attach("p", .network)
        loader.load(udid: "p", over: .network, from: source)
        #expect(await eventually(timeout: .seconds(1)) { source.loaded("p")?.info == Self.info })
        #expect(source.reads("p", .network) == 2)
    }
}
