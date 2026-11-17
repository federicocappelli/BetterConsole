import AppKit
import Observation
import SwiftUI
import BCFiles
import BCFilter
import BCModel
import BCStreaming

/// Opened log files: one window each, with no sidebar. Opening a file again brings its window
/// to the front. Each window's session lives in the registry while the window is open (so the
/// workspace's filter and the filter editor reach it like a device's) and is released on close.
@MainActor
enum LogFileWindows {
    private static var controllers: [LogDevice.ID: LogFileWindowController] = [:]
    private static var cascadePoint = NSPoint.zero

    /// File ▸ Open…: logs, plain text and JSON lines, several at once.
    static func showOpenPanel(environment: AppEnvironment) {
        let panel = NSOpenPanel()
        panel.title = "Open Logs"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = LogFileText.openableTypes
        guard panel.runModal() == .OK else { return }
        open(panel.urls, environment: environment)
    }

    /// Opens each file in its own window, or brings its open window to the front.
    static func open(_ urls: [URL], environment: AppEnvironment) {
        for url in urls where url.isFileURL {
            let transport = FileLogTransport(url: url)
            let id = transport.device.id
            RecentLogFiles.shared.note(url)
            if let existing = controllers[id] {
                existing.showWindow(nil)
                existing.window?.makeKeyAndOrderFront(nil)
                continue
            }
            let controller = LogFileWindowController(
                url: url, transport: transport, environment: environment)
            controller.onClose = { controllers[id] = nil }
            controllers[id] = controller
            if let window = controller.window {
                if cascadePoint == .zero { window.center() }
                cascadePoint = window.cascadeTopLeft(from: cascadePoint)
            }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
}

/// Whether an opened file's window is key. File windows are AppKit windows, so File ▸ Save
/// Logs… reads this to stay disabled while one is in front.
@MainActor @Observable
final class KeyLogFileWindow {
    static let shared = KeyLogFileWindow()
    var isKey = false
}

/// File ▸ Open Recent: the files opened lately, newest first (kept by AppKit's document
/// controller, so the Dock menu and Finder's recents agree).
@MainActor @Observable
final class RecentLogFiles {
    static let shared = RecentLogFiles()
    private(set) var urls: [URL] = NSDocumentController.shared.recentDocumentURLs

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        urls = NSDocumentController.shared.recentDocumentURLs
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        urls = []
    }
}

/// File ▸ Open… (⌘O) and File ▸ Open Recent.
struct OpenLogCommands: View {
    let environment: AppEnvironment
    private var recent: RecentLogFiles { .shared }

    var body: some View {
        Button("Open…") { LogFileWindows.showOpenPanel(environment: environment) }
            .keyboardShortcut("o")
        Menu("Open Recent") {
            ForEach(recent.urls, id: \.self) { url in
                Button(url.lastPathComponent) { LogFileWindows.open([url], environment: environment) }
            }
            if !recent.urls.isEmpty { Divider() }
            Button("Clear Menu") { recent.clear() }
                .disabled(recent.urls.isEmpty)
        }
    }
}

/// One opened file's window: the filter bar, the table and the detail pane of `LogView`, with
/// no sidebar and no streaming buttons.
final class LogFileWindowController: NSWindowController, NSWindowDelegate {
    private let session: StreamSession
    private let registry: SessionRegistry
    var onClose: () -> Void = {}

    init(url: URL, transport: FileLogTransport, environment: AppEnvironment) {
        registry = environment.registry
        session = registry.openFileSession(device: transport.device, transport: transport)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 300)
        window.title = url.lastPathComponent
        window.representedURL = url
        super.init(window: window)
        let hosting = NSHostingController(
            rootView: LogFileView(
                session: session, library: environment.library, workspace: environment.workspace,
                loadProgress: { transport.progress }))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.delegate = self
        session.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowDidBecomeKey(_ notification: Notification) {
        KeyLogFileWindow.shared.isKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        KeyLogFileWindow.shared.isKey = false
    }

    /// Releases the session (and its share of the memory budget); an open filter editor for
    /// the file keeps its edits but no longer previews against it.
    func windowWillClose(_ notification: Notification) {
        windowDidResignKey(notification)
        let id = session.device.id
        registry.closeFileSession(id: id)
        FilterEditorWindows.updateSession(nil, forDevice: id)
        window?.contentViewController = nil
        onClose()
    }
}

private struct LogFileView: View {
    let session: StreamSession
    let library: FilterLibrary
    let workspace: FilterWorkspace
    let loadProgress: @MainActor () -> Double

    var body: some View {
        LogView(
            session: session, library: library, workspace: workspace,
            loadProgress: loadProgress)
            // The main window's `filterLibraryAlerts` reports load problems once; here only the
            // lasting warning is shown.
            .environment(\.filterLibraryWarning, library.saveProblem)
            .frame(minWidth: 600, minHeight: 300)
    }
}
