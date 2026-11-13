import Testing
import Synchronization
import BCModel
@testable import BCStreaming

struct BoundedBatchQueueTests {
    @Test func dropsExcessAndCounts() {
        let queue = BoundedBatchQueue(capacity: 10)
        queue.push(makeEntries(0..<15))
        let first = queue.drain()
        #expect(first.entries.map(\.id) == Array(0..<10))
        #expect(first.dropped == 5)
        let second = queue.drain()
        #expect(second.entries.isEmpty)
        #expect(second.dropped == 0)
    }

    @Test func capacityFreedByDrain() {
        let queue = BoundedBatchQueue(capacity: 3)
        queue.push(makeEntries(0..<2))
        queue.push(makeEntries(2..<5))
        let first = queue.drain()
        #expect(first.entries.map(\.id) == [0, 1, 2])
        #expect(first.dropped == 2)
        queue.push(makeEntries(5..<7))
        let second = queue.drain()
        #expect(second.entries.map(\.id) == [5, 6])
        #expect(second.dropped == 0)
    }

    @Test func drainIsCappedAndLeftoverStaysQueued() {
        let queue = BoundedBatchQueue(capacity: 200_000)
        queue.push(makeEntries(0..<50_000))
        let a = queue.drain(max: 20_000), b = queue.drain(max: 20_000)
        let c = queue.drain(max: 20_000), d = queue.drain(max: 20_000)
        #expect(a.entries.count == 20_000 && a.entries.first?.id == 0)
        #expect(b.entries.count == 20_000 && b.entries.first?.id == 20_000)
        #expect(c.entries.count == 10_000 && c.entries.last?.id == 49_999)
        #expect(d.entries.isEmpty)
        #expect([a, b, c, d].map(\.dropped) == [0, 0, 0, 0])
    }

    @Test func cappedDrainReportsDroppedOnce() {
        let queue = BoundedBatchQueue(capacity: 30)
        queue.push(makeEntries(0..<40))
        let a = queue.drain(max: 20), b = queue.drain(max: 20)
        #expect(a.entries.count == 20 && a.dropped == 10)
        #expect(b.entries.count == 10 && b.dropped == 0)
    }

    /// 8 writers push 8,000 entries while a reader drains concurrently: nothing is lost or
    /// duplicated — every entry is either drained exactly once or counted as dropped.
    @Test func concurrentPushesAreSafe() async {
        let queue = BoundedBatchQueue(capacity: 1_000)
        let sink = Sink()
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for b in 0..<100 {
                        let base = UInt64(t * 10_000 + b * 10)
                        queue.push(makeEntries(base..<base + 10))
                    }
                }
            }
            group.addTask {
                for _ in 0..<200 {
                    sink.add(queue.drain())
                    await Task.yield()
                }
            }
        }
        sink.add(queue.drain())
        #expect(sink.ids.count + sink.dropped == 8_000)
        #expect(Set(sink.ids).count == sink.ids.count)
    }
}

private final class Sink: Sendable {
    private let state = Mutex<(ids: [UInt64], dropped: Int)>(([], 0))
    func add(_ r: (entries: [LogEntry], dropped: Int)) {
        state.withLock { $0.ids += r.entries.map(\.id); $0.dropped += r.dropped }
    }
    var ids: [UInt64] { state.withLock { $0.ids } }
    var dropped: Int { state.withLock { $0.dropped } }
}
