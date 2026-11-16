import AppKit
import SwiftUI
import BCFilter

/// The wrapping row of bubbles with "and"/"or" words between them and a text field after
/// the last one. Typing shows suggestions; ↑/↓ move, Return picks, Escape closes; Backspace
/// in the empty field selects the last bubble, a second Backspace removes it.
struct BubbleField: View {
    /// In display order (`BubbleLayout.ordered`).
    let bubbles: [Bubble]
    let seenValues: () -> SeenValues
    /// Called with the new list after every change.
    let onChange: ([Bubble]) -> Void

    static let lineHeight: CGFloat = 22
    static let lineSpacing: CGFloat = 4
    static let visibleLines: CGFloat = 3

    @State private var text = ""
    @State private var suggestions: [FilterSuggestion] = []
    @State private var highlighted = 0
    @State private var suggestionsClosed = false
    @State private var selected: Bubble.ID?
    @State private var editing: Bubble.ID?
    @State private var contentHeight: CGFloat = BubbleField.lineHeight

    private var maxHeight: CGFloat {
        Self.visibleLines * Self.lineHeight + (Self.visibleLines - 1) * Self.lineSpacing
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            FlowLayout(spacing: 4, lineSpacing: Self.lineSpacing) {
                ForEach(Array(bubbles.enumerated()), id: \.element.id) { index, bubble in
                    if index > 0 {
                        ConnectorWord(
                            connector: BubbleLayout.connector(between: bubbles[index - 1], and: bubble))
                    }
                    BubbleView(
                        bubble: bubble,
                        isSelected: selected == bubble.id,
                        isEditing: editing == bubble.id,
                        onChange: replace,
                        onRemove: { remove(bubble.id) },
                        onBeginEditing: { selected = nil; editing = bubble.id },
                        onEndEditing: { editing = nil })
                    .frame(minHeight: Self.lineHeight)
                }
                SuggestingTextField(
                    text: $text,
                    placeholder: bubbles.isEmpty ? "Filter" : "",
                    suggestions: suggestions,
                    highlighted: highlighted,
                    showsSuggestions: !suggestionsClosed,
                    onCommand: handle,
                    onPick: pick)
                .frame(minWidth: 120, minHeight: Self.lineHeight)
                .layoutValue(key: FlowFill.self, value: true)
                .id(Self.inputID)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.automatic)
        .frame(height: min(max(contentHeight, Self.lineHeight), maxHeight))
        .onChange(of: bubbles.map(\.id)) { _, ids in
            if let s = selected, !ids.contains(s) { selected = nil }
            if let e = editing, !ids.contains(e) { editing = nil }
            // Keep the text field in view once the bubbles scroll.
            proxy.scrollTo(Self.inputID, anchor: .bottom)
        }
        }
    }

    private static let inputID = "input"


    private var isShowingSuggestions: Bool { !suggestionsClosed && !suggestions.isEmpty }

    private func handle(_ command: SuggestingTextField.Command) -> Bool {
        switch command {
        case .textChanged(let value):
            selected = nil
            suggestionsClosed = false
            highlighted = 0
            suggestions = FilterSuggestions.make(for: value, seen: seenValues())
            return true
        case .up:
            guard isShowingSuggestions else { return false }
            highlighted = max(0, highlighted - 1)
            return true
        case .down:
            guard isShowingSuggestions else { return false }
            highlighted = min(suggestions.count - 1, highlighted + 1)
            return true
        case .enter:
            guard !suggestions.isEmpty else { return false }
            pick(isShowingSuggestions ? highlighted : 0)
            return true
        case .escape:
            if isShowingSuggestions {
                suggestionsClosed = true
                return true
            }
            if selected != nil {
                selected = nil
                return true
            }
            return false
        case .deleteBackward:
            guard text.isEmpty else {
                selected = nil
                return false
            }
            if let s = selected {
                remove(s)
            } else {
                selected = bubbles.last?.id
            }
            return true
        case .endEditing:
            suggestionsClosed = true
            return true
        }
    }

    private func pick(_ index: Int) {
        guard suggestions.indices.contains(index) else { return }
        let condition = suggestions[index].condition
        text = ""
        suggestions = []
        highlighted = 0
        onChange(BubbleEditing.adding(condition, include: true, to: bubbles))
    }

    private func replace(_ bubble: Bubble) {
        onChange(bubbles.map { $0.id == bubble.id ? bubble : $0 })
    }

    private func remove(_ id: Bubble.ID) {
        if selected == id { selected = nil }
        onChange(bubbles.filter { $0.id != id })
    }
}

private struct ConnectorWord: View {
    let connector: Connector

    var body: some View {
        Text(connector == .or ? "or" : "and")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(minHeight: BubbleField.lineHeight)
    }
}

// MARK: - Flow layout

/// Marks the subview that takes the rest of its line (the text field).
private struct FlowFill: LayoutValueKey {
    static let defaultValue = false
}

/// Places subviews left to right and wraps onto new lines, each line vertically centred.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? result.width, height: result.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews)
        -> (frames: [CGRect], width: CGFloat, height: CGFloat)
    {
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                lines.append([])
                x = 0
            }
            if subview[FlowFill.self], maxWidth.isFinite {
                size.width = max(size.width, maxWidth - x)
            }
            lines[lines.count - 1].append((index, size))
            x += size.width + spacing
        }

        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        var usedWidth: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map(\.size.height).max() ?? 0
            var x: CGFloat = 0
            for item in line {
                frames[item.index] = CGRect(
                    x: x, y: y + (height - item.size.height) / 2,
                    width: item.size.width, height: item.size.height)
                x += item.size.width + spacing
            }
            usedWidth = max(usedWidth, x - spacing)
            y += height + lineSpacing
        }
        return (frames, usedWidth, max(0, y - lineSpacing))
    }
}

// MARK: - Text field with suggestions

/// A borderless `NSTextField` that reports editing keys and shows `suggestions` in a popover
/// under itself while it is being edited. The popover never takes the keyboard, so typing
/// carries on in the field.
struct SuggestingTextField: NSViewRepresentable {
    enum Command {
        case textChanged(String)
        case up, down, enter, escape, deleteBackward, endEditing
    }

    @Binding var text: String
    var placeholder: String
    var suggestions: [FilterSuggestion]
    var highlighted: Int
    var showsSuggestions: Bool
    /// Returns whether the command was handled (otherwise the field does its default).
    var onCommand: (Command) -> Bool
    var onPick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if let editor = field.currentEditor() {
            if editor.string != text { editor.string = text }
        } else if field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.updatePopover(for: field)
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.closePopover()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SuggestingTextField
        private var popover: NSPopover?
        private var host: NSHostingController<SuggestionList>?

        init(parent: SuggestingTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            _ = parent.onCommand(.textChanged(field.stringValue))
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            _ = parent.onCommand(.endEditing)
            closePopover()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector)
            -> Bool
        {
            let command: Command? =
                switch selector {
                case #selector(NSResponder.moveUp(_:)): .up
                case #selector(NSResponder.moveDown(_:)): .down
                case #selector(NSResponder.insertNewline(_:)): .enter
                case #selector(NSResponder.cancelOperation(_:)): .escape
                case #selector(NSResponder.deleteBackward(_:)): .deleteBackward
                default: nil
                }
            guard let command else { return false }
            return parent.onCommand(command)
        }

        func updatePopover(for field: NSTextField) {
            let show = parent.showsSuggestions && !parent.suggestions.isEmpty
                && field.currentEditor() != nil && field.window != nil
            guard show else {
                closePopover()
                return
            }
            let list = SuggestionList(
                items: parent.suggestions, highlighted: parent.highlighted,
                onPick: { [weak self, weak field] index in
                    self?.parent.onPick(index)
                    if let field { field.window?.makeFirstResponder(field) }
                })
            let popover: NSPopover
            if let existing = self.popover, let host {
                host.rootView = list
                popover = existing
            } else {
                let host = NSHostingController(rootView: list)
                host.sizingOptions = [.preferredContentSize]
                popover = NSPopover()
                popover.behavior = .applicationDefined
                popover.animates = false
                popover.contentViewController = host
                self.host = host
                self.popover = popover
            }
            if !popover.isShown {
                // Under the start of the field, whichever way its coordinates run.
                let anchor = NSRect(
                    x: 0, y: 0, width: min(field.bounds.width, 60), height: field.bounds.height)
                popover.show(
                    relativeTo: anchor, of: field, preferredEdge: field.isFlipped ? .maxY : .minY)
                // Keep typing in the field, not the popover.
                field.window?.makeKey()
            }
        }

        func closePopover() {
            if popover?.isShown == true { popover?.close() }
        }
    }
}

/// The suggestion rows shown in the popover.
struct SuggestionList: View {
    let items: [FilterSuggestion]
    let highlighted: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(index == highlighted ? Color.white : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == highlighted ? Color.accentColor : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(index) }
            }
        }
        .padding(5)
        .frame(minWidth: 240, maxWidth: 480)
        .fixedSize()
    }
}
