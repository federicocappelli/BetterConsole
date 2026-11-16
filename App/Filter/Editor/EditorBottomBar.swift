import SwiftUI
import BCFilter
import BCStreaming

/// The live preview and Cancel / Apply / Save (ES §8.5, §8.6, §13.3).
struct EditorBottomBar: View {
    let state: FilterEditorState

    @Environment(\.controlActiveState) private var activeState

    private var model: FilterEditorModel { state.model }

    var body: some View {
        HStack(spacing: 10) {
            PreviewLabel(state: state, expression: model.previewExpression, isKey: activeState == .key)
            Spacer(minLength: 12)
            // Through the window's close, which asks first when there are unsaved changes.
            Button("Cancel") { state.window?.performClose(nil) }
            .keyboardShortcut(.cancelAction)
            Group {
                Button("Apply") { state.apply() }
                Button("Save") { state.save() }
            }
            .disabled(!model.canApply)
            .help(model.canApply ? "" : EditorText.fixErrorFirst)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// "Would match N of M messages on <device>", counted in the background over the device's
/// stored messages: about 200 ms after each change (cancelling the count before) and again
/// every 2 s while the window is in front.
private struct PreviewLabel: View {
    let state: FilterEditorState
    /// Resolved as the device's session would resolve it.
    let expression: FilterExpression?
    let isKey: Bool

    @State private var last: EditorText.Count?
    /// The expression `last` counted.
    @State private var counted: FilterExpression??
    @State private var isCounting = false
    @State private var stored = 0
    @State private var matchesEverything = false

    private struct Key: Equatable {
        var expression: FilterExpression?
        var isKey: Bool
        var session: ObjectIdentifier?
    }

    var body: some View {
        let preview = EditorText.preview(
            stored: stored, matchesEverything: matchesEverything, isCounting: isCounting, last: last)
        HStack(spacing: 6) {
            switch preview {
            case .count(let c):
                Text("Would match \(Text(c.matched.formatted()).bold()) of \(Text(c.total.formatted()).bold()) messages on \(state.deviceName)")
            case .counting(let previous):
                Text("Counting…")
                if let previous {
                    Text(EditorText.string(.count(previous), device: state.deviceName))
                        .foregroundStyle(.tertiary)
                }
            default:
                Text(EditorText.string(preview, device: state.deviceName))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .monospacedDigit()
        .task(id: Key(expression: expression, isKey: isKey, session: state.session.map(ObjectIdentifier.init))) {
            await run()
        }
    }

    private func run() async {
        // Read before the pause, so a device with messages never flashes "No messages … yet".
        stored = state.session?.store.count ?? 0
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        matchesEverything = CompiledFilter(expression).matchesEverything
        while !Task.isCancelled {
            stored = state.session?.store.count ?? 0
            if let session = state.session, stored > 0, !matchesEverything {
                // A new tree shows Counting…; a periodic recount keeps the number shown.
                if counted != .some(expression) { isCounting = true }
                guard let count = await session.countMatches(expression) else { return }
                last = EditorText.Count(matched: count.matched, total: count.total)
                counted = .some(expression)
                isCounting = false
            }
            guard isKey else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
