/// A set of absolute store positions kept as sorted, disjoint, non-adjacent ranges, so that
/// selecting every row of a large store stays one range.
public struct PositionRanges: Equatable, Sendable {
    public private(set) var ranges: [Range<Int>] = []

    public init() {}

    /// `ranges` in any order; overlapping and adjacent ones are merged, empty ones dropped.
    public init(_ ranges: [Range<Int>]) {
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = self.ranges.last, range.lowerBound <= last.upperBound {
                self.ranges[self.ranges.count - 1] =
                    last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
            } else {
                self.ranges.append(range)
            }
        }
    }

    public var isEmpty: Bool { ranges.isEmpty }

    /// Removes every position below `position`.
    public mutating func removeBelow(_ position: Int) {
        guard let first = ranges.first, first.lowerBound < position else { return }
        let keep = ranges.firstIndex { $0.upperBound > position } ?? ranges.count
        ranges.removeFirst(keep)
        if let first = ranges.first, first.lowerBound < position {
            ranges[0] = position..<first.upperBound
        }
    }

    public mutating func removeAll() { ranges.removeAll() }
}

/// A selection handed to a copy: its positions and the row generation (`LogRows.resetCount`)
/// they were taken from. Several rows' ranges only mean those rows within that generation, so
/// a copy stops once the rows reset; one position (`resetCount` nil) is valid in any.
public struct SelectedPositions: Sendable, Equatable {
    public let positions: PositionRanges
    public let resetCount: Int?

    public init(positions: PositionRanges, resetCount: Int?) {
        self.positions = positions
        self.resetCount = resetCount
    }
}
