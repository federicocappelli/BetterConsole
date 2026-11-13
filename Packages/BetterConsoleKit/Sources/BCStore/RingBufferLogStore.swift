import Foundation
import BCModel

/// Growable circular buffer over manually managed storage. Index 0 is the oldest entry.
/// Removal moves entries out of the buffer (no retain/release) and hands them to a background
/// queue to deinit, so evicting millions of entries never blocks the main actor.
@MainActor
public final class RingBufferLogStore: LogStore {
    /// Owns moved-out entries; deinitializes them wherever the last reference is dropped.
    private final class Garbage: @unchecked Sendable {
        let base: UnsafeMutablePointer<LogEntry>
        let count: Int
        init(base: UnsafeMutablePointer<LogEntry>, count: Int) {
            self.base = base
            self.count = count
        }
        deinit {
            base.deinitialize(count: count)
            base.deallocate()
        }
    }

    private var slots: UnsafeMutablePointer<LogEntry>
    /// Cached `estimatedBytes` per slot, so removal does not recompute it.
    private var sizes: UnsafeMutablePointer<Int>
    private var capacity: Int
    private var head = 0
    public private(set) var count = 0
    public private(set) var estimatedBytes = 0
    public private(set) var removedCount = 0

    public init(initialCapacity: Int = 1024) {
        capacity = max(initialCapacity, 1)
        slots = .allocate(capacity: capacity)
        sizes = .allocate(capacity: capacity)
    }

    isolated deinit {
        discardOffMain(moving: count, from: head)
        slots.deallocate()
        sizes.deallocate()
    }

    public var oldestDate: Date? { count == 0 ? nil : slots[head].date }

    public subscript(index: Int) -> LogEntry {
        precondition(index >= 0 && index < count, "Index out of range")
        var i = head + index
        if i >= capacity { i -= capacity }
        return slots[i]
    }

    public func append(contentsOf entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        reserve(count + entries.count)
        var tail = head + count
        if tail >= capacity { tail -= capacity }
        for entry in entries {
            let size = entry.estimatedBytes
            (slots + tail).initialize(to: entry)
            sizes[tail] = size
            estimatedBytes += size
            tail += 1
            if tail == capacity { tail = 0 }
        }
        count += entries.count
    }

    public func evictionCount(coveringBytes bytes: Int, maxCount: Int, olderThan: Date) -> Int {
        let limit = min(count, maxCount)
        var i = head
        var n = 0
        var freed = 0
        while n < limit, freed < bytes {
            if n > 0, slots[i].date >= olderThan { break }
            freed += sizes[i]
            n += 1
            i += 1
            if i == capacity { i = 0 }
        }
        return n
    }

    public func removeOldest(_ n: Int) {
        let n = min(max(n, 0), count)
        guard n > 0 else { return }
        var freed = 0
        var i = head
        for _ in 0..<n {
            freed += sizes[i]
            i += 1
            if i == capacity { i = 0 }
        }
        discardOffMain(moving: n, from: head)
        removedCount += n
        estimatedBytes -= freed
        head = i
        count -= n
        if count == 0 { head = 0 }
    }

    public func removeAll() {
        discardOffMain(moving: count, from: head)
        removedCount += count
        head = 0
        count = 0
        estimatedBytes = 0
    }

    /// Moves `n` entries starting at physical index `start` into a new buffer (at most two
    /// contiguous segments) and returns it as garbage.
    private func moveOut(_ n: Int, from start: Int) -> Garbage {
        let out = UnsafeMutablePointer<LogEntry>.allocate(capacity: max(n, 1))
        let first = min(n, capacity - start)
        out.moveInitialize(from: slots + start, count: first)
        if first < n { (out + first).moveInitialize(from: slots, count: n - first) }
        return Garbage(base: out, count: n)
    }

    private func discardOffMain(moving n: Int, from start: Int) {
        guard n > 0 else { return }
        let garbage = moveOut(n, from: start)
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(garbage) {} }
    }

    private func reserve(_ needed: Int) {
        guard needed > capacity else { return }
        var newCap = capacity
        while newCap < needed { newCap *= 2 }
        let newSlots = UnsafeMutablePointer<LogEntry>.allocate(capacity: newCap)
        let newSizes = UnsafeMutablePointer<Int>.allocate(capacity: newCap)
        let first = min(count, capacity - head)
        newSlots.moveInitialize(from: slots + head, count: first)
        newSizes.update(from: sizes + head, count: first)
        if first < count {
            (newSlots + first).moveInitialize(from: slots, count: count - first)
            (newSizes + first).update(from: sizes, count: count - first)
        }
        slots.deallocate()
        sizes.deallocate()
        slots = newSlots
        sizes = newSizes
        capacity = newCap
        head = 0
    }
}
