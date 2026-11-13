import BCModel
import Foundation
import Synchronization
import Testing
@testable import BCMobileDevice

struct DeviceRosterTests {
    static let udid = "00000000-0000000000000000"
    static let info = DeviceInfo(name: "PhoneVac", productType: "iPhone19,2", productVersion: "27.2.1")

    @Test func usbDeviceIsListedOnceInfoIsKnown() {
        var roster = DeviceRoster()
        let changed1 = roster.attached(udid: Self.udid, interface: .usb)
        #expect(changed1)
        #expect(roster.devices.isEmpty)  // no name yet
        let changed2 = roster.setInfo(Self.info, for: Self.udid)
        #expect(changed2)
        #expect(roster.devices == [
            LogDevice(id: Self.udid, name: "PhoneVac", kind: .physical, model: "iPhone 18 Pro", osVersion: "iOS 27.2.1"),
        ])
    }

    @Test func networkOnlyDeviceIsNotListed() {
        var roster = DeviceRoster()
        _ = roster.attached(udid: Self.udid, interface: .network)
        _ = roster.setInfo(Self.info, for: Self.udid)
        #expect(roster.devices.isEmpty)
    }

    /// The same phone is reported on USB and network at once; pulling the cable removes it
    /// even though the network interface remains (USB is the supported transport).
    @Test func unplugRemovesDeviceEvenIfNetworkRemains() {
        var roster = DeviceRoster()
        _ = roster.attached(udid: Self.udid, interface: .usb)
        _ = roster.attached(udid: Self.udid, interface: .network)
        _ = roster.setInfo(Self.info, for: Self.udid)
        #expect(roster.devices.count == 1)
        let changed3 = roster.detached(udid: Self.udid, interface: .usb)
        #expect(changed3)
        #expect(roster.devices.isEmpty)
        // Replug: info is remembered, the device is listed again immediately.
        let changed4 = roster.attached(udid: Self.udid, interface: .usb)
        #expect(changed4)
        #expect(roster.devices.map(\.name) == ["PhoneVac"])
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
        #expect(roster.devices.map(\.name) == ["PhoneVac"])
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
