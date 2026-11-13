import CoreGraphics
import Testing

/// Wheel and keyboard scrolling only show up as clip-view bounds changes; these drive the
/// tracker through the sequences the table produces.
@Suite struct FollowTrackerTests {
    static let clip = CGSize(width: 800, height: 400)

    /// Geometry with the clip at `originY` in a document `height` tall.
    static func at(_ originY: CGFloat, height: CGFloat = 10_000, clip: CGSize = clip) -> FollowTracker.Geometry {
        FollowTracker.Geometry(
            originY: originY, clipSize: clip, documentHeight: height,
            isAtBottom: originY + clip.height >= height - 9)
    }

    /// Following at the bottom, as after an update that scrolled to the newest row.
    static func followingAtBottom(height: CGFloat = 10_000) -> FollowTracker {
        var tracker = FollowTracker()
        tracker.recordOwnChange(at(height - clip.height, height: height))
        return tracker
    }

    @Test func wheelOrPageUpStopsFollowing() {
        var tracker = Self.followingAtBottom()
        tracker.boundsChanged(Self.at(9_600 - 54))  // three lines up
        #expect(!tracker.isFollowing)
    }

    @Test func staysStoppedWhileStreamingGrowsTheDocument() {
        var tracker = Self.followingAtBottom()
        tracker.boundsChanged(Self.at(9_000))
        // Updates add rows without scrolling (not following): recorded as our own change.
        tracker.recordOwnChange(Self.at(9_000, height: 10_180))
        tracker.recordOwnChange(Self.at(9_000, height: 10_360))
        #expect(!tracker.isFollowing)
        // Scrolling further up keeps it stopped; scrolling down short of the bottom too.
        tracker.boundsChanged(Self.at(8_000, height: 10_360))
        tracker.boundsChanged(Self.at(9_500, height: 10_360))
        #expect(!tracker.isFollowing)
    }

    @Test func reachingTheBottomResumesFollowing() {
        var tracker = Self.followingAtBottom()
        tracker.boundsChanged(Self.at(5_000))
        #expect(!tracker.isFollowing)
        tracker.boundsChanged(Self.at(9_600))  // End key or wheel down to the bottom
        #expect(tracker.isFollowing)
    }

    @Test func nowResumesFollowing() {
        var tracker = Self.followingAtBottom()
        tracker.boundsChanged(Self.at(5_000))
        tracker.isFollowing = true  // the Now button
        tracker.recordOwnChange(Self.at(9_600))
        #expect(tracker.isFollowing)
    }

    @Test func ownScrollsNeverStopFollowing() {
        var tracker = Self.followingAtBottom()
        // Front eviction keeping the top row moves the origin up; recorded, not judged.
        tracker.recordOwnChange(Self.at(9_000))
        #expect(tracker.isFollowing)
        // The next user move is judged against where our change left things.
        tracker.boundsChanged(Self.at(9_000 + 18))
        #expect(tracker.isFollowing)
    }

    @Test func resizeDoesNotStopFollowing() {
        var tracker = Self.followingAtBottom()
        let taller = CGSize(width: 800, height: 300)  // divider dragged / window shrunk
        tracker.boundsChanged(Self.at(9_000, clip: taller))
        #expect(tracker.isFollowing)
    }

    @Test func clampAfterDocumentShrinksDoesNotStopFollowing() {
        // Clear: the document shrinks and AppKit clamps the origin up.
        var tracker = Self.followingAtBottom()
        tracker.boundsChanged(Self.at(0, height: 360))
        #expect(tracker.isFollowing)
        tracker = Self.followingAtBottom()
        tracker.boundsChanged(Self.at(4_000, height: 5_000))
        #expect(tracker.isFollowing)
    }

    @Test func roundingAndHorizontalScrollDoNotStopFollowing() {
        var tracker = Self.followingAtBottom()
        tracker.boundsChanged(Self.at(9_600 - 0.25))
        #expect(tracker.isFollowing)
    }

    @Test func firstChangeWithoutHistoryIsNotJudged() {
        var tracker = FollowTracker()
        tracker.boundsChanged(Self.at(100))
        #expect(tracker.isFollowing)
    }
}
