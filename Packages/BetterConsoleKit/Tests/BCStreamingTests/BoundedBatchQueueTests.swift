import Testing
import Synchronization
import BCModel
@testable import BCStreaming

struct BoundedBatchQueueTests {
    @Test func dropsExcessAndCounts() {
        let queue = BoundedBatchQueue(capacity: 10)
        queue.push(tagged(0..<15))
        let first = flat(queue.drain())
        #expect(first.entries.map(\.id) == Array(0..<10))
        #expect(first.dropped == 5)
        let second = flat(queue.drain())
        #expect(second.entries.isEmpty)
        #expect(second.dropped == 0)
    }

    @Test func capacityFreedByDrain() {
        let queue = BoundedBatchQueue(capacity: 3)
        queue.push(tagged(0..<2))
        queue.push(tagged(2..<5))
        let first = flat(queue.drain())
        #expect(first.entries.map(\.id) == [0, 1, 2])
        #expect(first.dropped == 2)
        queue.push(tagged(5..<7))
        let second = flat(queue.drain())
        #expect(second.entries.map(\.id) == [5, 6])
        #expect(second.dropped == 0)
    }

    @Test func drainIsCappedAndLeftoverStaysQueued() {
        let queue = BoundedBatchQueue(capacity: 200_000)
        queue.push(tagged(0..<50_000))
        let a = flat(queue.drain(max: 20_000)), b = flat(queue.drain(max: 20_000))
        let c = flat(queue.drain(max: 20_000)), d = flat(queue.drain(max: 20_000))
        #expect(a.entries.count == 20_000 && a.entries.first?.id == 0)
        #expect(b.entries.count == 20_000 && b.entries.first?.id == 20_000)
        #expect(c.entries.count == 10_000 && c.entries.last?.id == 49_999)
        #expect(d.entries.isEmpty)
        #expect([a, b, c, d].map(\.dropped) == [0, 0, 0, 0])
    }

    @Test func cappedDrainReportsDroppedOnce() {
        let queue = BoundedBatchQueue(capacity: 30)
        queue.push(tagged(0..<40))
        let a = flat(queue.drain(max: 20)), b = flat(queue.drain(max: 20))
        #expect(a.entries.count == 20 && a.dropped == 10)
        #expect(b.entries.count == 10 && b.dropped == 0)
    }

    @Test func cutBatchKeepsMatchesAligned() {
        let queue = BoundedBatchQueue(capacity: 5)
        let pattern = [true, false, true, false, true, false, true, false]
        queue.push(TaggedBatch(entries: makeEntries(0..<8), matches: pattern, generation: 3))
        let r = queue.drain()
        #expect(r.batches.flatMap(\.entries).map(\.id) == [0, 1, 2, 3, 4])
        #expect(r.batches.flatMap { $0.matches ?? [] } == [true, false, true, false, true])
        #expect(r.batches.allSatisfy { $0.generation == 3 })
        #expect(r.dropped == 3)
    }

    @Test func drainCutByMaxKeepsMatchesAligned() {
        let queue = BoundedBatchQueue(capacity: 100)
        queue.push(TaggedBatch(
            entries: makeEntries(0..<4), matches: [true, false, false, true], generation: 1))
        queue.push(TaggedBatch(entries: makeEntries(4..<6), matches: nil, generation: 2))
        let a = queue.drain(max: 3), b = queue.drain(max: 3)
        #expect(a.batches.map { $0.entries.map(\.id) } == [[0, 1, 2]])
        #expect(a.batches.map(\.matches) == [[true, false, false]])
        #expect(b.batches.map { $0.entries.map(\.id) } == [[3], [4, 5]])
        #expect(b.batches.map(\.matches) == [[true], nil])
        #expect(b.batches.map(\.generation) == [1, 2])
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
                        queue.push(tagged(base..<base + 10))
                    }
                }
            }
            group.addTask {
                for _ in 0..<200 {
                    sink.add(flat(queue.drain()))
                    await Task.yield()
                }
            }
        }
        sink.add(flat(queue.drain()))
        #expect(sink.ids.count + sink.dropped == 8_000)
        #expect(Set(sink.ids).count == sink.ids.count)
    }
}

private func tagged(_ range: Range<UInt64>) -> TaggedBatch {
    TaggedBatch(entries: makeEntries(range), matches: nil, generation: 0)
}

private func flat(_ r: (batches: [TaggedBatch], dropped: Int)) -> (entries: [LogEntry], dropped: Int) {
    (r.batches.flatMap(\.entries), r.dropped)
}

private final class Sink: Sendable {
    private let state = Mutex<(ids: [UInt64], dropped: Int)>(([], 0))
    func add(_ r: (entries: [LogEntry], dropped: Int)) {
        state.withLock { $0.ids += r.entries.map(\.id); $0.dropped += r.dropped }
    }
    var ids: [UInt64] { state.withLock { $0.ids } }
    var dropped: Int { state.withLock { $0.dropped } }
}
