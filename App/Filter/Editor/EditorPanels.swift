import AppKit
import UniformTypeIdentifiers
import BCFilter

/// Import accepts `.bcfilter`, `.json`, `.txt` and files without an extension (ES §7.2).
final class ImportPanelFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        return EditorText.acceptsImport(url)
    }
}

/// The save panel's "Format" popup: Predicate text (the default) or JSON. The file extension
/// follows the choice.
@MainActor
final class ExportFormatPopup: NSObject {
    let view: NSView
    private let popup: NSPopUpButton
    private weak var panel: NSSavePanel?
    private static let formats: [(title: String, format: FilterFileFormat)] =
        [("Predicate text", .predicate), ("JSON", .json)]

    init(panel: NSSavePanel, name: String) {
        self.panel = panel
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Self.formats.map(\.title))
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(formatChanged)
        panel.allowedContentTypes = [Self.contentType(for: .predicate)]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = EditorText.exportFileName(
            name: name, fileExtension: FilterFileFormat.predicate.fileExtension)
    }

    var format: FilterFileFormat { Self.formats[max(popup.indexOfSelectedItem, 0)].format }

    @objc private func formatChanged() {
        guard let panel else { return }
        panel.allowedContentTypes = [Self.contentType(for: format)]
        panel.nameFieldStringValue = EditorText.renamed(
            panel.nameFieldStringValue, toExtension: format.fileExtension)
    }

    private static func contentType(for format: FilterFileFormat) -> UTType {
        switch format {
        case .json: .json
        case .predicate: UTType(filenameExtension: format.fileExtension) ?? .data
        }
    }
}
