/// The positions of a session's rows at one moment (Save Logs), exact whatever happens to the
/// rows afterwards: a filter change, a rescan or new rows do not change it; positions evicted
/// since are skipped when it is read. Taking one is O(1) (the filtered index is shared
/// copy-on-write; the session's next change to its index copies it once).
public struct RowSnapshot: Sendable {
    enum Storage: Sendable {
        case contiguous(Range<Int>)
        case filtered(MatchIndex)
    }

    let storage: Storage

    public var count: Int {
        switch storage {
        case .contiguous(let range): range.count
        case .filtered(let index): index.count
        }
    }

    /// The position of row `index` of the snapshot.
    func position(at index: Int) -> Int {
        switch storage {
        case .contiguous(let range): range.lowerBound + index
        case .filtered(let matches): matches[index]
        }
    }

    /// The first row whose position is at or after `position`, or `count` if none is.
    func firstIndex(atOrAfter position: Int) -> Int {
        switch storage {
        case .contiguous(let range):
            return Swift.min(Swift.max(0, position - range.lowerBound), range.count)
        case .filtered(let matches):
            return matches.row(atOrBefore: position - 1).map { $0 + 1 } ?? 0
        }
    }
}
