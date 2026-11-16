import SwiftUI
import BCFilter
import BCStreaming

/// Above the log list (spec §6): the saved-filter dropdown, the bubble field, filtering
/// progress, Save and the "…" menu. Every change goes through `FilterWorkspace`, which keeps
/// the device's state, the library and other devices in step.
struct FilterBar: View {
    let session: StreamSession
    let library: FilterLibrary
    let workspace: FilterWorkspace

    @Environment(\.filterLibraryWarning) private var libraryWarning

    /// In display order. Kept here (not re-read from the tree on every render) so bubble ids
    /// stay stable for selection and inline editing.
    @State private var bubbles: [Bubble]
    @State private var nameSheet: NameSheetRequest?
    @State private var unsavedPick: FilterPick?
    @State private var deleteRequest: DeleteRequest?
    @State private var importRejections: ImportRejections?
    @State private var exportError: String?

    init(session: StreamSession, library: FilterLibrary, workspace: FilterWorkspace) {
        self.session = session
        self.library = library
        self.workspace = workspace
        _bubbles = State(
            initialValue: BubbleCodec.bubbles(from: workspace.state(for: session.device.id).expression))
    }

    private var deviceID: String { session.device.id }
    private var state: DeviceFilterState { workspace.state(for: deviceID) }
    private var name: String { workspace.displayName(for: deviceID) }
    private var isUntitled: Bool { state.basedOn == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            filterMenu
            BubbleField(
                bubbles: bubbles,
                seenValues: { [session] in session.seenValues },
                onChange: apply)
            .frame(maxWidth: .infinity)
            FilteringProgress(session: session)
            if let libraryWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .frame(height: BubbleField.lineHeight)
                    .help(libraryWarning)
                    .accessibilityLabel(libraryWarning)
            }
            Button("Save") { save(then: nil) }
                .disabled(!canSave)
                .frame(height: BubbleField.lineHeight)
            moreMenu
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .onChange(of: state.expression) { _, expression in
            // Changed outside this field (another filter picked, saved from another device…).
            if expression != BubbleCodec.expression(from: bubbles) {
                bubbles = BubbleCodec.bubbles(from: expression)
            }
        }
        .sheet(item: $nameSheet) { request in
            NameSheet(request: request) { name in commitName(name, for: request) }
        }
        .unsavedEditsPrompt(
            $unsavedPick, name: name,
            onSave: { save(then: $0) },
            onDiscard: { workspace.select($0.filterID, for: deviceID) })
        .deleteFilterConfirmation($deleteRequest) { workspace.delete($0.id) }
        .importRejectionsAlert($importRejections)
        .filterErrorAlert($exportError)
    }

    // MARK: Dropdown

    private var filterMenu: some View {
        Menu {
            Button("New Filter") { pick(.newFilter) }
            Divider()
            ForEach(library.filters) { filter in
                Toggle(
                    filter.name,
                    isOn: Binding(
                        get: { state.basedOn == filter.id },
                        set: { _ in pick(.filter(filter.id)) }))
            }
        } label: {
            Text(state.isEdited ? "\(name) (Edited)" : name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220)
        }
        .fixedSize()
        .frame(minHeight: BubbleField.lineHeight)
        .help("Saved filters")
    }

    private func pick(_ pick: FilterPick) {
        if hasUnsavedWork {
            unsavedPick = pick
        } else {
            workspace.select(pick.filterID, for: deviceID)
        }
    }

    /// Edits worth asking about: anything edited except an empty Untitled.
    private var hasUnsavedWork: Bool {
        state.isEdited && !(isUntitled && state.expression == nil)
    }

    // MARK: Save and the "…" menu

    private var canSave: Bool { isUntitled ? !bubbles.isEmpty : state.isEdited }

    /// Untitled asks for a name first (as Save As).
    private func save(then pick: FilterPick?) {
        if isUntitled {
            nameSheet = NameSheetRequest(kind: .saveAs, initialName: name, then: pick)
            return
        }
        workspace.save(for: deviceID)
        if let pick { workspace.select(pick.filterID, for: deviceID) }
    }

    private func commitName(_ name: String, for request: NameSheetRequest) {
        switch request.kind {
        case .saveAs:
            workspace.saveAs(name: name, for: deviceID)
            if let then = request.then { workspace.select(then.filterID, for: deviceID) }
        case .rename(let id):
            workspace.rename(id, to: name)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Save As…") {
                nameSheet = NameSheetRequest(kind: .saveAs, initialName: name)
            }
            Button("Rename…") {
                if let id = state.basedOn {
                    nameSheet = NameSheetRequest(kind: .rename(id), initialName: name)
                }
            }
            .disabled(isUntitled)
            // Menus do not show `.help` tooltips, so the hint is also the item's subtitle.
            Button {} label: {
                Text("Edit")
                Text("Coming soon")
            }
            .disabled(true)
            .help("Coming soon")
            Button("Duplicate") { workspace.duplicate(for: deviceID) }
                .disabled(isUntitled)
            Divider()
            Button("Export…", action: export)
                .disabled(isUntitled)
            Button("Import…", action: importFiles)
            Divider()
            Button("Delete…") {
                if let id = state.basedOn { deleteRequest = DeleteRequest(id: id, name: name) }
            }
            .disabled(isUntitled)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(minHeight: BubbleField.lineHeight)
        .help("More filter actions")
    }

    private func export() {
        guard let id = state.basedOn, let url = FilterPanels.chooseExportURL(name: name) else { return }
        do {
            try library.export(id: id, to: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func importFiles() {
        guard let urls = FilterPanels.chooseImportFiles() else { return }
        let report = library.importFiles(urls)
        if !report.rejected.isEmpty { importRejections = ImportRejections(files: report.rejected) }
    }

    // MARK: Bubbles

    private func apply(_ edited: [Bubble]) {
        let ordered = BubbleLayout.ordered(edited)
        let expression = BubbleCodec.expression(from: ordered)
        bubbles = ordered
        if expression != BubbleCodec.expression(from: BubbleCodec.bubbles(from: state.expression)) {
            workspace.setExpression(expression, for: deviceID)
        }
    }
}

/// "Filtering…" with a small determinate progress view while the session rescans. Its own
/// view so progress updates re-render only this.
private struct FilteringProgress: View {
    let session: StreamSession

    var body: some View {
        if session.isFiltering {
            HStack(spacing: 6) {
                Text("Filtering…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ProgressView(value: session.filterProgress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 60)
            }
            .frame(height: BubbleField.lineHeight)
        }
    }
}
