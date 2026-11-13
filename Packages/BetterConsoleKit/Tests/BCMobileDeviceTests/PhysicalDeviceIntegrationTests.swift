import BCModel
import Foundation
import Synchronization
import Testing
@testable import BCMobileDevice

/// Runs against a real device only when `BC_DEVICE_UDID` names one attached over USB:
/// `BC_DEVICE_UDID=<udid> swift test --filter PhysicalDeviceIntegrationTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BC_DEVICE_UDID"] != nil))
struct PhysicalDeviceIntegrationTests {
    static let udid = ProcessInfo.processInfo.environment["BC_DEVICE_UDID"] ?? ""

    @Test func discoversAndStreamsFromRealDevice() async throws {
        // Discovery: the device appears with its name, model and OS version.
        let found = Task { () -> LogDevice? in
            for await devices in MobileDeviceDiscovery().devices() {
                if let device = devices.first(where: { $0.id == Self.udid }) { return device }
            }
            return nil
        }
        let timeout = Task { try await Task.sleep(for: .seconds(15)); found.cancel() }
        let device = try #require(await found.value)
        timeout.cancel()
        print("discovered: \(device)")
        #expect(device.kind == .physical)

        // Streaming: entries arrive in batches of at most 1,000.
        let transport = MobileDeviceLogTransport()
        #expect(transport.supports(device))
        let received = Mutex((count: 0, maxBatch: 0, sample: [LogEntry]()))
        let consumer = Task {
            for try await batch in transport.stream(from: device) {
                received.withLock {
                    $0.count += batch.count
                    $0.maxBatch = max($0.maxBatch, batch.count)
                    if $0.sample.count < 5 { $0.sample += batch.prefix(5 - $0.sample.count) }
                }
            }
        }
        try await Task.sleep(for: .seconds(5))
        let cancelledAt = ContinuousClock.now
        consumer.cancel()
        let result = await consumer.result
        let stopTime = ContinuousClock.now - cancelledAt
        let r = received.withLock { $0 }
        print("received \(r.count) entries in 5 s, largest batch \(r.maxBatch), stopped in \(stopTime)")
        for e in r.sample { print("  \(e.date) [\(e.level)] \(e.process)[\(e.pid ?? -1)] \(e.subsystem ?? "-")/\(e.category ?? "-"): \(e.message.prefix(80))") }
        if case .failure(let error) = result { Issue.record("stream failed: \(error)") }
        #expect(r.count > 100)
        #expect(r.maxBatch <= 1_000)
        #expect(stopTime < .seconds(2))
    }
}
