import Foundation
import Testing

@MainActor @Suite struct EditorUndoRoutingTests {
    /// ⌘Z within the typing pause: the flush finds the error, so the text view's undo applies
    /// and the typed characters are not replaced by a model undo.
    @Test func flushesBeforeDeciding() {
        var hasError = false
        var flushed = 0
        let routing = EditorUndoRouting(
            flush: { flushed += 1; hasError = true },
            textHasError: { hasError },
            textHasFocus: { true })
        #expect(routing.target() == .text)
        #expect(flushed == 1)
    }

    @Test func modelUnlessFocusedTextHasAnError() {
        for (error, focus, expected) in [
            (false, false, EditorUndoRouting.Target.model), (true, false, .model),
            (false, true, .model), (true, true, .text),
        ] {
            let routing = EditorUndoRouting(flush: {}, textHasError: { error }, textHasFocus: { focus })
            #expect(routing.target() == expected)
            #expect(routing.currentTarget == expected)
        }
    }

    /// The toolbar's enabled state reads the target without flushing.
    @Test func currentTargetDoesNotFlush() {
        var flushed = false
        let routing = EditorUndoRouting(flush: { flushed = true }, textHasError: { false }, textHasFocus: { false })
        _ = routing.currentTarget
        #expect(!flushed)
    }
}
