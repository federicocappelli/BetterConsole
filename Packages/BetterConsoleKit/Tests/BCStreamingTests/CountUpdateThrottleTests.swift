import Testing
@testable import BCStreaming

/// The detail pane's "N messages selected" while eviction shrinks a selection: count-only
/// changes go out at most every 250 ms; any other change goes out at once.
struct CountUpdateThrottleTests {
    let start = ContinuousClock.now

    @Test func countChangesAreSpacedOut() {
        var throttle = CountUpdateThrottle()
        #expect(throttle.delay(at: start, countOnly: false) == .zero)  // the selection
        #expect(throttle.delay(at: start + .milliseconds(100), countOnly: true) == .milliseconds(150))
        #expect(throttle.delay(at: start + .milliseconds(200), countOnly: true) == .milliseconds(50))
        #expect(throttle.delay(at: start + .milliseconds(250), countOnly: true) == .zero)
        #expect(throttle.delay(at: start + .milliseconds(300), countOnly: true) == .milliseconds(200))
        #expect(throttle.delay(at: start + .milliseconds(600), countOnly: true) == .zero)
    }

    @Test func otherChangesAreNeverDelayed() {
        var throttle = CountUpdateThrottle()
        #expect(throttle.delay(at: start, countOnly: true) == .zero)
        #expect(throttle.delay(at: start + .milliseconds(10), countOnly: false) == .zero)
        #expect(throttle.delay(at: start + .milliseconds(20), countOnly: false) == .zero)
        // The last change counts from the latest one sent.
        #expect(throttle.delay(at: start + .milliseconds(30), countOnly: true) == .milliseconds(240))
    }
}
