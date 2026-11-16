/// Ascending absolute store positions of the messages matching a filter; row r of the filtered
/// table is the r-th smallest position.
///
/// Stored as two arrays so both ends grow and shrink cheaply: `older` holds the positions the
/// rescan has found so far, newest first (so evicting the oldest is `removeLast`), and `newer`
/// holds live appends in ascending order, with `newerHead` marking its logically dropped front.
struct MatchIndex {
    private var older: [Int] = []
    private var newer: [Int] = []
    private var newerHead = 0
    /// Largest position appended since the last `removeAll`; keeps the ascending check O(1).
    private var lastAppended = Int.min

    init() {}

    var count: Int { older.count + newer.count - newerHead }

    subscript(row: Int) -> Int {
        precondition(row >= 0 && row < count, "row out of range")
        if row < older.count { return older[older.count - 1 - row] }
        return newer[newerHead + row - older.count]
    }

    /// `position` must be greater than every position already stored.
    mutating func append(_ position: Int) {
        precondition(position > lastAppended, "positions must ascend")
        lastAppended = position
        newer.append(position)
    }

    /// `positionsNewestFirst` must be descending and all below the current first position.
    mutating func prepend(_ positionsNewestFirst: [Int]) {
        guard let first = positionsNewestFirst.first else { return }
        precondition(count == 0 || first < self[0], "positions must precede the first")
        assert(zip(positionsNewestFirst, positionsNewestFirst.dropFirst()).allSatisfy { $0 > $1 },
               "positions must be strictly descending")
        if count == 0 { lastAppended = first }
        older.append(contentsOf: positionsNewestFirst)
    }

    /// Removes positions below `position` from the front; returns how many rows went.
    mutating func dropBelow(_ position: Int) -> Int {
        var removed = 0
        while let last = older.last, last < position {
            older.removeLast()
            removed += 1
        }
        guard older.isEmpty else { return removed }
        while newerHead < newer.count, newer[newerHead] < position {
            newerHead += 1
            removed += 1
        }
        if newerHead == newer.count {
            newer.removeAll(keepingCapacity: true)
            newerHead = 0
        } else if newerHead > 1024, newerHead * 2 > newer.count {
            newer.removeFirst(newerHead)
            newerHead = 0
        }
        return removed
    }

    mutating func removeAll() {
        older.removeAll()
        newer.removeAll()
        newerHead = 0
        lastAppended = Int.min
    }

    func row(forPosition position: Int) -> Int? {
        guard let row = row(atOrBefore: position), self[row] == position else { return nil }
        return row
    }

    /// The last row whose position is at or before `position`, or nil if none is.
    func row(atOrBefore position: Int) -> Int? {
        // Binary search for the number of rows with a position <= `position`.
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] <= position { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}
