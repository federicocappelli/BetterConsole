import AppKit
import SwiftUI
import BCModel
import BCStreaming
import BCTransport

@main
struct BetterConsoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("BetterConsole", id: "main") {
            RootView(registry: appDelegate.environment.registry)
        }
        .defaultSize(width: 1100, height: 700)

        Settings {
            SettingsView(budget: appDelegate.environment.budget)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created once with the delegate, so it outlives any view.
    let environment = AppEnvironment.live()

    func applicationDidFinishLaunching(_ notification: Notification) {
        environment.start()
        environment.startProbeIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // No orphaned `log` / `simctl` children after quit.
        ChildProcessRegistry.shared.terminateAll()
    }
}

struct RootView: View {
    let registry: SessionRegistry
    @State private var selection: LogDevice.ID? = "local"

    var body: some View {
        NavigationSplitView {
            DeviceSidebar(rows: registry.rows, selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            if let selection, let session = registry.session(for: selection) {
                LogView(session: session)
                    .id(selection)
            } else {
                ContentUnavailableView("No Device Selected", systemImage: "sidebar.left")
            }
        }
        .onChange(of: registry.rows) {
            // The selected row is gone (device vanished with nothing to show, or its logs
            // were cleared while disconnected): fall back to this Mac.
            let valid = registry.validSelection(selection)
            if valid != selection { selection = valid }
        }
    }
}
