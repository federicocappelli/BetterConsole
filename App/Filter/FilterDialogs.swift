import AppKit
import SwiftUI
import BCFilter

/// What the user picked in the filter dropdown.
enum FilterPick: Equatable {
    case newFilter
    case filter(UUID)

    var filterID: UUID? {
        if case .filter(let id) = self { id } else { nil }
    }
}

// MARK: - Name sheet

struct NameSheetRequest: Identifiable {
    enum Kind: Equatable {
        case saveAs
        case rename(UUID)
    }

    let id = UUID()
    var kind: Kind
    var initialName: String
    /// Picked after saving, when the sheet came from the unsaved-edits prompt.
    var then: FilterPick?
}

/// "Save Filter" / "Rename Filter": a name field, prefilled, and Save/Rename and Cancel.
struct NameSheet: View {
    let request: NameSheetRequest
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(request: NameSheetRequest, onCommit: @escaping (String) -> Void) {
        self.request = request
        self.onCommit = onCommit
        _name = State(initialValue: request.initialName)
    }

    private var isRename: Bool { request.kind != .saveAs }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRename ? "Rename Filter" : "Save Filter").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

// MARK: - Alerts

struct DeleteRequest: Identifiable {
    let id: UUID
    let name: String
    /// Saved filters that link this one directly (`FilterWorkspace.directDependentsNames`),
    /// sorted: their links stop matching.
    var dependents: [String] = []

    var message: String {
        dependents.isEmpty
            ? "This can't be undone."
            : EditorText.deleteWithDependents(name: name, dependents: dependents)
    }
}

/// What Import reports: the files it rejected and the links nothing resolved.
struct ImportProblems: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init?(_ report: FilterLibrary.ImportReport) {
        guard let text = EditorText.importReport(rejected: report.rejected, missingLinks: report.missingLinks)
        else { return nil }
        title = text.title
        message = text.message
    }
}

extension View {
    /// `Save changes to “<name>”?` with Save, Discard and Cancel.
    func unsavedEditsPrompt(
        _ pick: Binding<FilterPick?>, name: String,
        onSave: @escaping (FilterPick) -> Void, onDiscard: @escaping (FilterPick) -> Void
    ) -> some View {
        alert(
            "Save changes to “\(name)”?",
            isPresented: Binding(get: { pick.wrappedValue != nil }, set: { if !$0 { pick.wrappedValue = nil } }),
            presenting: pick.wrappedValue
        ) { pick in
            Button("Save") { onSave(pick) }
            Button("Discard", role: .destructive) { onDiscard(pick) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your changes will be lost if you don't save them.")
        }
    }

    /// `Delete “<name>”?` with Delete and Cancel: "This can't be undone.", or the filters
    /// that link it (ES §9).
    func deleteFilterConfirmation(
        _ request: Binding<DeleteRequest?>, onDelete: @escaping (DeleteRequest) -> Void
    ) -> some View {
        alert(
            "Delete “\(request.wrappedValue?.name ?? "")”?",
            isPresented: Binding(
                get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
            presenting: request.wrappedValue
        ) { r in
            Button("Delete", role: .destructive) { onDelete(r) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text(r.message)
        }
    }

    /// Lists the files Import rejected, with their reasons, and the links it couldn't resolve.
    func importProblemsAlert(_ problems: Binding<ImportProblems?>) -> some View {
        alert(
            problems.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { problems.wrappedValue != nil }, set: { if !$0 { problems.wrappedValue = nil } }),
            presenting: problems.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { r in
            Text(r.message)
        }
    }

    /// A plain error alert (export failures).
    func filterErrorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Couldn't Export Filter",
            isPresented: Binding(
                get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } }),
            presenting: message.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { m in
            Text(m)
        }
    }

    /// The library's load problem once at launch (then acknowledged) and its save problem
    /// whenever one appears. While saving is off or failing, `filterLibraryWarning` carries
    /// the message so the filter bar can keep it discoverable.
    func filterLibraryAlerts(library: FilterLibrary) -> some View {
        modifier(FilterLibraryAlerts(library: library))
    }
}

extension EnvironmentValues {
    /// A library problem that lasts for the session (saving off or failing), or nil.
    @Entry var filterLibraryWarning: String?
}

private struct FilterLibraryAlerts: ViewModifier {
    let library: FilterLibrary

    @State private var loadMessage: String?
    /// Set when the damaged library could not be set aside: nothing is saved this session.
    @State private var savingDisabledMessage: String?
    @State private var saveMessage: String?

    func body(content: Content) -> some View {
        content
            .environment(\.filterLibraryWarning, library.saveProblem ?? savingDisabledMessage)
            .onAppear {
                guard let problem = library.loadProblem else { return }
                if problem == FilterLibrary.notSetAsideMessage { savingDisabledMessage = problem }
                loadMessage = problem
            }
            .alert(
                "Saved Filters Couldn't Be Read",
                isPresented: Binding(
                    get: { loadMessage != nil },
                    set: { if !$0 { acknowledgeLoadProblem() } }),
                presenting: loadMessage
            ) { _ in
                Button("OK", role: .cancel) { acknowledgeLoadProblem() }
            } message: { m in
                Text(m)
            }
            .onChange(of: library.saveProblem) { _, problem in
                if let problem { saveMessage = problem }
            }
            .alert(
                "Filters Couldn't Be Saved",
                isPresented: Binding(
                    get: { saveMessage != nil && loadMessage == nil },
                    set: { if !$0 { saveMessage = nil } }),
                presenting: saveMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { m in
                Text(m)
            }
    }

    private func acknowledgeLoadProblem() {
        loadMessage = nil
        library.acknowledgeLoadProblem()
    }
}

// MARK: - Panels

@MainActor
enum FilterPanels {
    /// Open panel for one or more filter files (`.bcfilter`, `.json`, `.txt` or no
    /// extension, as the editor's Import); nil when cancelled.
    static func chooseImportFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Import Filters"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let filter = ImportPanelFilter()
        panel.delegate = filter
        let response = panel.runModal()
        withExtendedLifetime(filter) {}
        guard response == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }

    /// Save panel with the editor's Format popup (Predicate text by default, or JSON),
    /// suggesting `<name>.<extension>`; nil when cancelled.
    static func chooseExport(name: String) -> (url: URL, format: FilterFileFormat)? {
        let panel = NSSavePanel()
        panel.title = "Export Filter"
        panel.prompt = "Export"
        let format = ExportFormatPopup(panel: panel, name: name)
        panel.accessoryView = format.view
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, format.format)
    }
}
