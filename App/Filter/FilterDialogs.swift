import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
}

struct ImportRejections: Identifiable {
    let id = UUID()
    let files: [(fileName: String, reason: String)]

    var message: String {
        files.map { "\($0.fileName): \($0.reason)" }.joined(separator: "\n")
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

    /// `Delete “<name>”?` — "This can't be undone." with Delete and Cancel.
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
        } message: { _ in
            Text("This can't be undone.")
        }
    }

    /// Lists the files Import rejected, with their reasons.
    func importRejectionsAlert(_ rejections: Binding<ImportRejections?>) -> some View {
        alert(
            rejections.wrappedValue.map {
                $0.files.count == 1 ? "A file couldn't be imported" : "\($0.files.count) files couldn't be imported"
            } ?? "",
            isPresented: Binding(
                get: { rejections.wrappedValue != nil }, set: { if !$0 { rejections.wrappedValue = nil } }),
            presenting: rejections.wrappedValue
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
    /// Open panel for one or more `.json` filter files; nil when cancelled.
    static func chooseImportFiles() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Import Filters"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }

    /// Save panel suggesting `<name>.json`; nil when cancelled.
    static func chooseExportURL(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Filter"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safe).json"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
