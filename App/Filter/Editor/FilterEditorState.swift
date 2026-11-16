import AppKit
import SwiftUI
import BCFilter
import BCStreaming

/// What the editor window's views share besides the model.
@MainActor @Observable
final class FilterEditorState {
    let model: FilterEditorModel
    let deviceName: String
    var session: StreamSession?
    let workspace: FilterWorkspace
    let library: FilterLibrary
    /// The builder row selected, from the builder or by clicking in the text.
    var selectedNodeID: UUID?
    /// Set when a click in the text selected the row, so the text isn't scrolled back to it.
    @ObservationIgnored var selectionFromText = false
    var nameSheet: NameSheetRequest?
    /// After "Copy as log predicate"; cleared after a few seconds.
    var copiedMessage: String?

    @ObservationIgnored weak var window: NSWindow?
    /// The text pane: its own undo for typing while the text has an error (ES §8.4).
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored let textUndo = UndoManager()
    /// Hands typed text the model hasn't read yet to it now (set by the text pane).
    @ObservationIgnored var flushText: () -> Void = {}

    init(
        model: FilterEditorModel, deviceName: String, session: StreamSession?,
        workspace: FilterWorkspace, library: FilterLibrary
    ) {
        self.model = model
        self.deviceName = deviceName
        self.session = session
        self.workspace = workspace
        self.library = library
    }

    var filterName: String { workspace.displayName(for: model.deviceID) }

    /// ⌘Z and the toolbar's ↶ undo tree changes, except while the text pane has focus and its
    /// text has an error: then they undo typing (ES §8.4). Typed text is handed to the model
    /// before deciding.
    var undoRouting: EditorUndoRouting {
        EditorUndoRouting(
            flush: { [weak self] in self?.flushText() },
            textHasError: { [weak self] in self?.model.textError != nil },
            textHasFocus: { [weak self] in
                guard let self, let textView = self.textView else { return false }
                return self.window?.firstResponder === textView
            })
    }

    /// The undo manager ⌘Z should use now (flushes typed text first).
    var currentUndoManager: UndoManager? {
        undoRouting.target() == .text ? textUndo : window.flatMap { ($0 as? EditorWindow)?.modelUndo }
    }

    /// For the toolbar: whether ↶ / ↷ would do anything, without flushing.
    var canUndo: Bool { undoRouting.currentTarget == .text ? textUndo.canUndo : model.canUndo }
    var canRedo: Bool { undoRouting.currentTarget == .text ? textUndo.canRedo : model.canRedo }

    func undo() {
        if undoRouting.target() == .text { textUndo.undo() } else { model.undo() }
    }

    func redo() {
        if undoRouting.target() == .text { textUndo.redo() } else { model.redo() }
    }

    // MARK: Apply and Save

    func apply() {
        flushText()
        model.apply()
    }

    func save() {
        flushText()
        switch model.save() {
        case .saved, .textHasError: break
        case .needsName: nameSheet = NameSheetRequest(kind: .saveAs, initialName: filterName)
        case .refusedLoop: showAlert(title: EditorText.includesItself(filterName), message: nil)
        case .tooDeep: showAlert(title: EditorText.tooDeep, message: nil)
        }
    }

    func saveAs(name: String) { model.saveAs(name: name) }

    func copyAsLogPredicate() {
        let (text, removed) = model.copyAsLogPredicate()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let message = EditorText.copied(removed: removed)
        copiedMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.copiedMessage == message { self?.copiedMessage = nil }
        }
    }

    // MARK: Files

    func importFile() {
        guard let window else { return }
        flushText()
        let panel = NSOpenPanel()
        panel.title = "Import Filter"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let filter = ImportPanelFilter()
        panel.delegate = filter
        panel.beginSheetModal(for: window) { [weak self] response in
            _ = filter
            guard response == .OK, let url = panel.url else { return }
            self?.importFile(url)
        }
    }

    private func importFile(_ url: URL) {
        do {
            try model.importFile(url)
        } catch {
            showAlert(title: "Couldn't Import Filter", message: Self.describe(error))
            return
        }
        let missing = model.lastImportMissingLinks
        if !missing.isEmpty {
            showAlert(
                title: missing.count == 1 ? "A linked filter wasn't found" : "Some linked filters weren't found",
                message: EditorText.missingLinks(missing))
        }
    }

    func export() {
        guard let window else { return }
        flushText()
        let panel = NSSavePanel()
        panel.title = "Export Filter"
        panel.prompt = "Export"
        let format = ExportFormatPopup(panel: panel, name: filterName)
        panel.accessoryView = format.view
        // The completion keeps the popup (the panel only holds its view).
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.model.export(to: url, format: format.format)
            } catch {
                self.showAlert(title: "Couldn't Export Filter", message: Self.describe(error))
            }
        }
    }

    // MARK: Closing

    /// Asks "Discard your changes to the filter?"; `discard` runs after Discard. Keep Editing
    /// is the default button (Return) and Esc chooses it too: an NSAlert button has one key
    /// equivalent, so Esc is caught by a key monitor while the sheet is up.
    func askToDiscard(then discard: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = EditorText.discardQuestion
        alert.addButton(withTitle: "Keep Editing")
        let discardButton = alert.addButton(withTitle: "Discard")
        discardButton.hasDestructiveAction = true
        discardButton.keyEquivalent = ""
        alert.buttons[0].keyEquivalent = "\r"
        let sheet = alert.window
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak sheet] event in
            guard event.keyCode == 53, let window, let sheet, event.window === sheet,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            else { return event }
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            return nil
        }
        alert.beginSheetModal(for: window) { response in
            if let escape { NSEvent.removeMonitor(escape) }
            if response == .alertSecondButtonReturn { discard() }
        }
    }

    // MARK: Private

    private func showAlert(title: String, message: String?) {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? FilterImportError { return error.description }
        return error.localizedDescription
    }
}
