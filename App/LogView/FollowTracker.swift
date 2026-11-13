import CoreGraphics

/// Decides whether the log table keeps following new rows, from the clip view's geometry.
///
/// Live-scroll notifications only arrive for trackpad gestures and scroller drags. A classic
/// mouse wheel, Page Up / Home and other keyboard scrolling only change the clip view's
/// bounds, so a bounds change the coordinator did not make itself counts as the user's:
/// moving up (same clip size, document not shrunk) stops following, reaching the bottom
/// resumes it. Window resizes, divider drags and the clamp after the document shrinks
/// (Clear) leave following alone.
struct FollowTracker {
    struct Geometry: Equatable {
        /// Clip bounds origin in the (flipped) table's coordinates: smaller is further up.
        var originY: CGFloat
        var clipSize: CGSize
        var documentHeight: CGFloat
        var isAtBottom: Bool
    }

    /// Movements smaller than this are rounding, not scrolling.
    static let tolerance: CGFloat = 0.5

    var isFollowing = true
    private var last: Geometry?

    /// The coordinator scrolled or resized the table itself (follow, keeping the top row
    /// after front eviction, Now): remember where it left things without judging the move.
    mutating func recordOwnChange(_ geometry: Geometry) {
        last = geometry
    }

    /// A bounds change the coordinator did not make: the user's (wheel, keyboard), or AppKit
    /// adjusting to a resize.
    mutating func boundsChanged(_ geometry: Geometry) {
        defer { last = geometry }
        if geometry.isAtBottom {
            isFollowing = true
            return
        }
        guard let last,
              geometry.clipSize == last.clipSize,
              geometry.documentHeight >= last.documentHeight
        else { return }
        if geometry.originY < last.originY - Self.tolerance {
            isFollowing = false
        }
    }
}
