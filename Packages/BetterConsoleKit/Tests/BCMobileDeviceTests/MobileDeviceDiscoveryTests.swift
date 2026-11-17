import BCModel
import Foundation
import Synchronization
import Testing
@testable import BCMobileDevice

struct DeviceRosterTests {
    static let udid = "00000000-0000000000000000"
    static let info = DeviceInfo(name: "Test iPhone", productType: "iPhone19,2", productVersion: "27.2.1")

    @Test func usbDeviceIsListedOnceInfoIsKnown() {
        var roster = DeviceRoster()
        let changed1 = roster.attached(udid: Self.udid, interface: .usb)
        #expect(changed1)
        #expect(roster.devices.isEmpty)  // no name yet
        let changed2 = roster.setInfo(Self.info, for: Self.udid)
        #expect(changed2)
        #expect(roster.devices == [
            LogDevice(id: Self.udid, name: "Test iPhone", kind: .physical, model: "iPhone 18 Pro", osVersion: "iOS 27.2.1",
                      connection: .usb),
        ])
    }

    @Test func networkOnlyDeviceIsListedAsWifi() {
        var roster = DeviceRoster()
        _ = roster.attached(udid: Self.udid, interface: .network)
        _ = roster.setInfo(Self.info, for: Self.udid)
        #expect(roster.devices.map(\.connection) == [.wifi])
        #expect(roster.interfaces(of: Self.udid) == [.network])
    }

    /// The same phone is reported on USB and network at once: one device, USB preferred.
    @Test func deviceOnBothInterfacesIsListedOnceAsUSB() {
        var roster = DeviceRoster()
        _ = roster.attached(udid: Self.udid, interface: .network)
        _ = roster.attached(udid: Self.udid, interface: .usb)
        _ = roster.setInfo(Self.info, for: Self.udid)
        #expect(roster.devices.map(\.id) == [Self.udid])
        #expect(roster.devices.first?.connection == .usb)
        #expect(roster.interfaces(of: Self.udid) == [.usb, .network])
    }

    /// Pulling the cable keeps the device listed while it is still on the network; it goes
    /// only when gone from both.
    @Test func unplugKeepsDeviceOnWifiUntilGoneFromBoth() {
        var roster = DeviceRoster()
        _ = roster.attached(udid: Self.udid, interface: .usb)
        _ = roster.attached(udid: Self.udid, interface: .network)
        _ = roster.setInfo(Self.info, for: Self.udid)
        let changed3 = roster.detached(udid: Self.udid, interface: .usb)
        #expect(changed3)
        #expect(roster.devices.map(\.connection) == [.wifi])
        let changed4 = roster.detached(udid: Self.udid, interface: .network)
        #expect(changed4)
        #expect(roster.devices.isEmpty)
        #expect(roster.interfaces(of: Self.udid).isEmpty)
        // Replug: info is remembered, the device is listed again immediately.
        let changed5 = roster.attached(udid: Self.udid, interface: .usb)
        #expect(changed5)
        #expect(roster.devices.map(\.name) == ["Test iPhone"])
        #expect(roster.devices.first?.connection == .usb)
    }

    /// Wi-Fi going away while on USB leaves the device as it was.
    @Test func networkLossWhileOnUSBKeepsDeviceOnUSB() {
        var roster = DeviceRoster()
        _ = roster.attached(udid: Self.udid, interface: .usb)
        _ = roster.attached(udid: Self.udid, interface: .network)
        _ = roster.setInfo(Self.info, for: Self.udid)
        let before = roster.devices
        _ = roster.detached(udid: Self.udid, interface: .network)
        #expect(roster.devices == before)
    }

    /// A device seen only on Wi-Fi is listed once its real info is known, never under the
    /// generic fallback name (USB devices keep the fallback).
    @Test func networkOnlyDeviceNeedsRealInfo() {
        var roster = DeviceRoster()
        _ = roster.attached(udid: Self.udid, interface: .network)
        let fallback = DeviceInfo(name: "iOS Device", productType: nil, productVersion: nil)
        _ = roster.setInfo(fallback, for: Self.udid, provisional: true)
        #expect(roster.devices.isEmpty)
        _ = roster.attached(udid: Self.udid, interface: .usb)
        #expect(roster.devices.map(\.name) == ["iOS Device"])
        _ = roster.detached(udid: Self.udid, interface: .usb)
        #expect(roster.devices.isEmpty)
        _ = roster.setInfo(Self.info, for: Self.udid)
        #expect(roster.devices.map(\.name) == ["Test iPhone"])
    }

    @Test func otherInterfacesAreNotListed() {
        var roster = DeviceRoster()
        _ = roster.attached(udid: Self.udid, interface: .other)
        _ = roster.setInfo(Self.info, for: Self.udid)
        #expect(roster.devices.isEmpty)
    }

    /// The "iOS Device" fallback is listed but not cached: the next attach re-reads info.
    @Test func fallbackInfoIsProvisional() {
        var roster = DeviceRoster()
        _ = roster.attached(udid: Self.udid, interface: .usb)
        let fallback = DeviceInfo(name: "iOS Device", productType: nil, productVersion: nil)
        _ = roster.setInfo(fallback, for: Self.udid, provisional: true)
        #expect(roster.devices.map(\.name) == ["iOS Device"])
        #expect(!roster.hasInfo(Self.udid))
        _ = roster.setInfo(Self.info, for: Self.udid)
        #expect(roster.hasInfo(Self.udid))
        #expect(roster.devices.map(\.name) == ["Test iPhone"])
    }

    /// A fallback name stored after the real one (a slow USB read losing a race with a Wi-Fi
    /// read) is ignored.
    @Test func provisionalInfoNeverReplacesRealInfo() {
        var roster = DeviceRoster()
        _ = roster.attached(udid: Self.udid, interface: .usb)
        _ = roster.setInfo(Self.info, for: Self.udid)
        let fallback = DeviceInfo(name: "iOS Device", productType: nil, productVersion: nil)
        let changed = roster.setInfo(fallback, for: Self.udid, provisional: true)
        #expect(!changed)
        #expect(roster.hasInfo(Self.udid))
        #expect(roster.devices.map(\.name) == ["Test iPhone"])
    }

    @Test func duplicateEventsReportNoChange() {
        var roster = DeviceRoster()
        let changed5 = roster.attached(udid: Self.udid, interface: .usb)
        #expect(changed5)
        let changed6 = roster.attached(udid: Self.udid, interface: .usb)
        #expect(!changed6)
        let changed7 = roster.detached(udid: "other", interface: .usb)
        #expect(!changed7)
    }

    @Test func devicesAreSortedByName() {
        var roster = DeviceRoster()
        for (id, name) in [("b", "Zed"), ("a", "Alpha")] {
            _ = roster.attached(udid: id, interface: .usb)
            _ = roster.setInfo(DeviceInfo(name: name, productType: nil, productVersion: nil), for: id)
        }
        #expect(roster.devices.map(\.name) == ["Alpha", "Zed"])
        #expect(roster.devices.first?.model == nil)
        #expect(roster.devices.first?.osVersion == nil)
    }

    @Test func modelNames() {
        #expect(DeviceInfo.marketingName("iPhone19,2") == "iPhone 18 Pro")
        #expect(DeviceInfo.marketingName("iPhone17,1") == "iPhone 16 Pro")
        #expect(DeviceInfo.marketingName("iPhone99,9") == "iPhone99,9")
    }
}

final class FakeDeviceSource: DeviceListSource {
    private let state = Mutex<(current: [LogDevice], subscribers: [Int: @Sendable ([LogDevice]) -> Void], next: Int)>(([], [:], 0))

    func subscribe(_ onChange: @escaping @Sendable ([LogDevice]) -> Void) -> Int {
        state.withLock { state in
            let token = state.next
            state.next += 1
            state.subscribers[token] = onChange
            onChange(state.current)
            return token
        }
    }

    func unsubscribe(_ token: Int) { state.withLock { _ = $0.subscribers.removeValue(forKey: token) } }

    func publish(_ devices: [LogDevice]) {
        state.withLock { state in
            state.current = devices
            for subscriber in state.subscribers.values { subscriber(devices) }
        }
    }

    var subscriberCount: Int { state.withLock { $0.subscribers.count } }
}

struct MobileDeviceDiscoveryTests {
    @Test func unavailableFrameworkEmitsEmptyListAndStaysOpen() async {
        let discovery = MobileDeviceDiscovery(source: nil)
        var iterator = discovery.devices().makeAsyncIterator()
        #expect(await iterator.next() == [])
        let next = Task { await iterator.next() }
        try? await Task.sleep(for: .milliseconds(100))
        next.cancel()
    }

    @Test func forwardsSourceUpdatesAndUnsubscribesOnTermination() async {
        let source = FakeDeviceSource()
        let discovery = MobileDeviceDiscovery(source: source)
        do {
            var iterator = discovery.devices().makeAsyncIterator()
            #expect(await iterator.next() == [])
            source.publish([phone])
            #expect(await iterator.next() == [phone])
            source.publish([])
            #expect(await iterator.next() == [])
            #expect(source.subscriberCount == 1)
        }
        #expect(await eventually { source.subscriberCount == 0 })
    }
}
