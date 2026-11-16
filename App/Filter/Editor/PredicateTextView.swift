import AppKit
import SwiftUI
import BCFilter

/// The right side of the editor (ES §8.3, §6.5): the predicate text, its error, and the
/// compatibility note with "Copy as log predicate".
struct PredicatePane: View {
    let state: FilterEditorState

    private var model: FilterEditorModel { state.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PredicateTextView(
                state: state, text: model.text, error: model.textError, selected: state.selectedNodeID)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.textError {
                    Label(error.message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                note
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var note: some View {
        let hasAppOnly = !model.text.appOnlyRanges.isEmpty
        Text(LocalizedStringKey(EditorText.compatibilityNote(hasAppOnlyParts: hasAppOnly)))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if hasAppOnly {
            HStack(spacing: 8) {
                Button(EditorText.copyAsLogPredicate) { state.copyAsLogPredicate() }
                    .disabled(!model.canApply)
                    .help(model.canApply ? "Copy the text without the highlighted parts" : EditorText.fixErrorFirst)
                if let copied = state.copiedMessage {
                    Text(copied).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A monospaced `NSTextView` showing `FilterEditorModel.text`. Typing is handed to the model
/// about 300 ms after the last keystroke and when focus leaves (ES §8.3).
struct PredicateTextView: NSViewRepresentable {
    let state: FilterEditorState
    /// Passed in (not read from the model here) so SwiftUI updates the view when they change.
    let text: PredicateText
    let error: PredicateParseError?
    let selected: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = Coordinator.font
        textView.typingAttributes = Coordinator.baseAttributes
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        state.textView = textView
        state.flushText = { [weak coordinator = context.coordinator] in coordinator?.flush() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sync(text: text, error: error, selected: selected)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        static let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.textColor,
        ]

        let state: FilterEditorState
        weak var textView: NSTextView?
        /// The model text last shown; a different one is a change from the builder, undo,
        /// Import or the device, and replaces what the view shows.
        private var shownModelText: String?
        /// Typed and not yet handed to the model.
        private var hasPendingTyping = false
        private var pending: Task<Void, Never>?
        private var settingText = false
        private var lastSelected: UUID?

        init(state: FilterEditorState) { self.state = state }

        func sync(text: PredicateText, error: PredicateParseError?, selected: UUID?) {
            guard let textView else { return }
            if text.text != shownModelText {
                shownModelText = text.text
                if textView.string != text.text {
                    pending?.cancel()
                    hasPendingTyping = false
                    replaceText(with: text.text)
                }
            }
            highlight()
            if selected != lastSelected {
                lastSelected = selected
                if !state.selectionFromText, let selected, let range = nsRange(state.model.textRange(for: selected)) {
                    textView.scrollRangeToVisible(range)
                }
            }
        }

        /// Hands typed text to the model now.
        func flush() {
            pending?.cancel()
            pending = nil
            guard hasPendingTyping, let textView else { return }
            hasPendingTyping = false
            state.model.textDidChange(textView.string)
        }

        // MARK: NSTextViewDelegate

        func undoManager(for view: NSTextView) -> UndoManager? { state.textUndo }

        func textDidChange(_ notification: Notification) {
            guard !settingText else { return }
            hasPendingTyping = true
            highlight()
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            flush()
            state.model.endTextEditing()
        }

        /// A click (or caret move) in the text selects the row written there.
        func textViewDidChangeSelection(_ notification: Notification) {
            // Only the user's own clicks and caret moves, not a reflow after focus left.
            guard !settingText, let textView, !hasPendingTyping,
                  textView.window?.firstResponder === textView,
                  textView.string == state.model.text.text
            else { return }
            // The index must be the model string's own: the view's bridged string indexes
            // differently after a non-ASCII character.
            let location = textView.selectedRange().location
            guard let index = PredicateTextMapping.index(utf16Offset: location, in: state.model.text.text),
                  let id = state.model.nodeID(at: index), id != state.selectedNodeID
            else { return }
            state.selectionFromText = true
            state.selectedNodeID = id
        }

        // MARK: Private

        private func replaceText(with string: String) {
            guard let textView, let storage = textView.textStorage else { return }
            settingText = true
            defer { settingText = false }
            let selection = textView.selectedRange()
            storage.replaceCharacters(
                in: NSRange(location: 0, length: storage.length),
                with: NSAttributedString(string: string, attributes: Self.baseAttributes))
            let length = (string as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            // Character undo never reaches across a change made elsewhere.
            state.textUndo.removeAllActions()
        }

        /// Keys, operators, strings; app-only parts tinted; `//` lines dimmed; the error
        /// underlined in red; the selected row's text highlighted.
        private func highlight() {
            // Leave text being composed (an input method's marked text) alone.
            guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let string = textView.string
            let spans = PredicateSyntax.spans(in: string)
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(Self.baseAttributes, range: full)
            for span in spans {
                guard let range = PredicateTextMapping.nsRange(span.range, in: string) else { continue }
                switch span.role {
                case .key: storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: range)
                case .keyword: storage.addAttribute(.foregroundColor, value: NSColor.systemPink, range: range)
                case .operator: storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                case .string: storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
                case .number: storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
                case .value: storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: range)
                case .disabledLine: break
                }
            }
            // Dim whole `//` lines last, over the colours inside them.
            for span in spans where span.role == .disabledLine {
                guard let range = PredicateTextMapping.nsRange(span.range, in: string) else { continue }
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            }
            let model = state.model
            // Model ranges index the model's text (and convert against it); while typing ahead
            // of it they don't apply.
            if string == model.text.text {
                for r in model.text.appOnlyRanges {
                    if let range = nsRange(r) {
                        storage.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.18), range: range)
                    }
                }
                if let id = state.selectedNodeID, let range = nsRange(model.textRange(for: id)) {
                    storage.addAttribute(
                        .backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.22), range: range)
                }
                if let error = model.textError, var range = nsRange(error.range) {
                    // An error at the end of the text underlines the last character.
                    if range.length == 0, range.location > 0 {
                        range = NSRange(location: range.location - 1, length: 1)
                    }
                    storage.addAttributes(
                        [
                            .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                            .underlineColor: NSColor.systemRed,
                            .toolTip: error.message,
                        ], range: range)
                }
            }
            storage.endEditing()
            textView.typingAttributes = Self.baseAttributes
        }

        /// A range of the model's text in the view (equal text, UTF-16 offsets).
        private func nsRange(_ range: Range<String.Index>?) -> NSRange? {
            range.flatMap { PredicateTextMapping.nsRange($0, in: state.model.text.text) }
        }
    }
}
