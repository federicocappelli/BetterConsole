import Foundation
import Testing
import BCModel
@testable import BCTransport

struct SimulatorDiscoveryTests {
    static func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/simctl-booted", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test func parsesBootedDevices() throws {
        let devices = try SimulatorDiscovery.parse(Self.fixture())
        #expect(devices.count == 2)
        let old = try #require(devices.first { $0.id == "61277C51-172A-4EF7-8028-B04016930958" })
        #expect(old.name == "iPhone 16 Pro")
        #expect(old.kind == .simulator)
        #expect(old.model == "iPhone 16 Pro")
        #expect(old.osVersion == "iOS 18.6")
        let new = try #require(devices.first { $0.id == "AAAAAAAA-0000-4000-8000-000000000002" })
        #expect(new.osVersion == "iOS 27.2")
        #expect(new.model == "iPhone 17 Pro")
    }

    @Test func emitsOnlyOnChange() async throws {
        let a = try Self.fixture()
        let b = Data(#"{"devices":{}}"#.utf8)
        let responses = Responses([a, a, b])
        let discovery = SimulatorDiscovery(interval: .milliseconds(5), runner: { await responses.next() })
        var seen: [Int] = []
        for await list in discovery.devices() {
            seen.append(list.count)
            if seen.count == 2 { break }
        }
        #expect(seen == [2, 0])
    }

    /// Before any list has been emitted, a failure yields [] so the sidebar initializes.
    @Test func firstRunnerFailureEmitsEmpty() async {
        struct Boom: Error {}
        let discovery = SimulatorDiscovery(interval: .milliseconds(5), runner: { throw Boom() })
        var first: [LogDevice]?
        for await list in discovery.devices() { first = list; break }
        #expect(first == [])
    }

    /// Later failures (simctl error or timeout) keep the last list instead of reporting
    /// every simulator as gone.
    @Test func laterRunnerFailuresKeepLastList() async throws {
        struct Boom: Error {}
        let a = try Self.fixture()
        let b = Data(#"{"devices":{}}"#.utf8)
        let script = Script([.failure(Boom()), .success(a), .failure(Boom()), .failure(Boom()), .success(b)])
        let discovery = SimulatorDiscovery(interval: .milliseconds(5), runner: { try await script.next() })
        var seen: [Int] = []
        var callsAtEmit: [Int] = []
        for await list in discovery.devices() {
            seen.append(list.count)
            callsAtEmit.append(await script.calls)
            if seen.count == 3 { break }
        }
        #expect(seen == [0, 2, 0])
        // The third list came from `b` (call 5), not from the failures at calls 3 and 4.
        #expect(callsAtEmit.last.map { $0 >= 5 } == true)
    }

    @Test func pollingStopsAfterConsumerCancels() async throws {
        let counter = Counter()
        let discovery = SimulatorDiscovery(interval: .milliseconds(5), runner: { await counter.bump(); return Data(#"{"devices":{}}"#.utf8) })
        for await _ in discovery.devices() { break }
        try await Task.sleep(for: .milliseconds(50))
        let settled = await counter.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(await counter.value == settled)
    }

    @Test func hungProcessIsKilledOnTimeout() async throws {
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await SimulatorDiscovery.runProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellationKillsProcess() async throws {
        let task = Task {
            try await SimulatorDiscovery.runProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        _ = await task.result
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func runProcessReturnsOutput() async throws {
        let data = try await SimulatorDiscovery.runProcess(executable: "/bin/echo", arguments: ["hi"], timeout: .seconds(5))
        #expect(String(decoding: data, as: UTF8.self) == "hi\n")
    }

    @Test func localMacEmitsOnce() async {
        var all: [[LogDevice]] = []
        for await list in LocalMacDiscovery().devices() { all.append(list) }
        #expect(all.count == 1)
        #expect(all[0].first?.id == "local")
        #expect(all[0].first?.kind == .thisMac)
    }
}

private actor Responses {
    var items: [Data]
    init(_ items: [Data]) { self.items = items }
    func next() -> Data { items.count > 1 ? items.removeFirst() : items[0] }
}

private actor Script {
    var items: [Result<Data, Error>]
    var calls = 0
    init(_ items: [Result<Data, Error>]) { self.items = items }
    func next() throws -> Data {
        calls += 1
        return try (items.count > 1 ? items.removeFirst() : items[0]).get()
    }
}

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}
