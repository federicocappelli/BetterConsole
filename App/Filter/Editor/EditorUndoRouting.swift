import Foundation

/// Which history ⌘Z / ⇧⌘Z use (ES §8.4): the text view's own while it has focus and its text
/// has an error, otherwise the model's tree history.
@MainActor
struct EditorUndoRouting {
    enum Target: Equatable { case text, model }

    /// Hands typed text the model hasn't read yet to it.
    let flush: () -> Void
    let textHasError: () -> Bool
    let textHasFocus: () -> Bool

    /// For an undo or redo: flushes first, so text typed within the typing pause counts (an
    /// error it has keeps the typed characters under the text view's own undo).
    func target() -> Target {
        flush()
        return currentTarget
    }

    /// Without flushing, for enabling buttons.
    var currentTarget: Target { textHasFocus() && textHasError() ? .text : .model }
}
