import AppKit
import SwiftUI
import BCFilter
import BCStreaming

/// The filter editor windows (ES §8): one per device; opening it again brings the existing
/// one to the front.
@MainActor
enum FilterEditorWindows {
    private static var controllers: [String: FilterEditorWindowController] = [:]

    static func open(
        deviceID: String, deviceName: String, session: StreamSession?,
        workspace: FilterWorkspace, library: FilterLibrary
    ) {
        if let existing = controllers[deviceID] {
            // A reconnected device has a new session.
            existing.state.session = session
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let state = FilterEditorState(
            model: FilterEditorModel(deviceID: deviceID, workspace: workspace, library: library),
            deviceName: deviceName, session: session, workspace: workspace, library: library)
        let controller = FilterEditorWindowController(state: state)
        controller.onClose = { controllers[deviceID] = nil }
        controllers[deviceID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Points an open editor's preview at the device's current session (for instance after
    /// the device reconnected); nothing when no editor is open for it.
    static func updateSession(_ session: StreamSession?, forDevice deviceID: String) {
        controllers[deviceID]?.state.session = session
    }
}

final class FilterEditorWindowController: NSWindowController, NSWindowDelegate {
    let state: FilterEditorState
    var onClose: () -> Void = {}
    private var closeConfirmed = false

    init(state: FilterEditorState) {
        self.state = state
        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 380)
        window.tabbingMode = .disallowed
        let hosting = NSHostingController(rootView: FilterEditorView(state: state))
        hosting.sceneBridgingOptions = [.toolbars]
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1120, height: 620))
        window.center()
        window.modelUndo.state = state
        super.init(window: window)
        window.delegate = self
        state.window = window
        observeTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// "Edit Filter — <name>", plus " (Edited)".
    private func observeTitle() {
        let title = withObservationTracking {
            state.model.title
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeTitle() }
        }
        window?.title = title
    }

    /// The close button, ⌘W and Cancel (`performClose`): with unsaved changes, asks first and
    /// closes after Discard.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        state.flushText()
        if closeConfirmed || !state.model.hasUnsavedChanges { return true }
        state.askToDiscard { [weak self] in
            self?.closeConfirmed = true
            self?.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// Routes ⌘Z / ⇧⌘Z and Edit ▸ Undo/Redo (ES §8.4): `undo:` reaches the window, which asks
/// its undo manager.
final class EditorWindow: NSWindow {
    let modelUndo = ModelUndoManager()

    override var undoManager: UndoManager? {
        modelUndo.state?.currentUndoManager ?? modelUndo
    }
}

/// The window's undo manager for tree changes: Undo and Redo go to the model's history.
/// Anything registered with it (a builder text field's typing) is ignored; the model records
/// each builder change itself.
final class ModelUndoManager: UndoManager {
    weak var state: FilterEditorState?

    override init() {
        super.init()
        levelsOfUndo = 1
    }

    override var canUndo: Bool { state?.model.canUndo ?? false }
    override var canRedo: Bool { state?.model.canRedo ?? false }
    override func undo() { state?.undo() }
    override func redo() { state?.redo() }
    override var undoMenuItemTitle: String { "Undo" }
    override var redoMenuItemTitle: String { "Redo" }
}

// MARK: - Root view

/// Layout B (ES §8): the builder on the left, the predicate text on the right, the preview
/// and Cancel / Apply / Save at the bottom.
struct FilterEditorView: View {
    @Bindable var state: FilterEditorState

    private var model: FilterEditorModel { state.model }

    var body: some View {
        VStack(spacing: 0) {
            if model.externalChange {
                ExternalChangeBanner(model: model)
                Divider()
            }
            HSplitView {
                BuilderView(state: state)
                    .frame(minWidth: 380, idealWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                PredicatePane(state: state)
                    .frame(minWidth: 300, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            EditorBottomBar(state: state)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .help("Undo")
                    .disabled(!state.canUndo)
                Button { state.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .help("Redo")
                    .disabled(!state.canRedo)
                Button("Import…") { state.importFile() }
                    .help("Replace this filter with one from a file")
                Button("Export…") { state.export() }
                    .disabled(!model.canApply)
                    .help(model.canApply ? "Save this filter to a file" : EditorText.fixErrorFirst)
            }
        }
        .sheet(item: $state.nameSheet) { request in
            NameSheet(request: request) { name in state.saveAs(name: name) }
        }
    }
}

/// "This filter was changed in the filter bar." with Reload / Keep my version (ES §8.1).
private struct ExternalChangeBanner: View {
    let model: FilterEditorModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.yellow)
            Text(EditorText.bannerMessage)
            Spacer()
            Button("Reload") { model.reloadFromDevice() }
            Button("Keep my version") { model.keepMine() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.12))
    }
}
