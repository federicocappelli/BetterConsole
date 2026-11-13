import SwiftUI
import BCModel
import BCStreaming

/// The log pane for one session: toolbar, banners, empty state, the table and the detail pane.
struct LogView: View {
    let session: StreamSession
    /// Bumped by the Now button; the table scrolls to the bottom and resumes following.
    @State private var nowRequest = 0
    @State private var selectedEntry: LogEntry?

    // `session.revision` changes up to 10 times a second, so only small child views read it
    // (subtitle, empty state); the table observes it itself. This body, with the toolbar,
    // re-renders on state changes only.
    var body: some View {
        VStack(spacing: 0) {
            if let banner {
                banner
                Divider()
            }
            ZStack {
                LogTableView(
                    session: session, nowRequest: nowRequest,
                    onSelect: { selectedEntry = $0 },
                    detail: LogDetailView(entry: selectedEntry))
                EmptyStateOverlay(session: session)
            }
        }
        .background { SessionSubtitle(session: session) }
        .navigationTitle(session.device.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if session.state == .streaming || session.state == .disconnected(wasStreaming: true) {
                    Button("Pause", systemImage: "pause.fill") { session.pause() }
                        .help("Pause streaming")
                } else {
                    Button("Start", systemImage: "play.fill") { session.start() }
                        .help("Start streaming")
                }
                Button("Now", systemImage: "arrow.down.to.line") { nowRequest += 1 }
                    .help("Jump to the latest message")
                Button("Clear", systemImage: "trash") { session.clear() }
                    .help("Clear messages")
            }
        }
    }


    private var banner: Banner? {
        switch session.state {
        case .disconnected(let wasStreaming):
            Banner(
                symbol: "cable.connector.slash",
                message: wasStreaming
                    ? "Device disconnected — will resume when it reconnects"
                    : "Device disconnected",
                action: nil)
        case .failed(let message):
            Banner(
                symbol: "exclamationmark.triangle.fill", message: message,
                action: ("Retry", { session.retry() }))
        case .idle, .streaming, .paused:
            nil
        }
    }
}

private struct Banner: View {
    let symbol: String
    let message: String
    let action: (title: String, run: @MainActor () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(message).lineLimit(2).textSelection(.enabled)
            Spacer()
            if let action {
                Button(action.title, action: action.run)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Sets the window subtitle (message and dropped counts), at most `refreshInterval` apart:
/// a subtitle change re-lays out the window title bar (several ms), and `revision` changes
/// up to 10 times a second.
private struct SessionSubtitle: View {
    static let refreshInterval: Duration = .milliseconds(250)

    let session: StreamSession
    @State private var subtitle = ""

    var body: some View {
        Color.clear
            .navigationSubtitle(subtitle)
            .task(id: ObjectIdentifier(session)) {
                // `Observations` coalesces changes made while this loop sleeps.
                for await (count, dropped) in Observations({ [session] in
                    _ = session.revision
                    return (session.store.count, session.droppedCount)
                }) {
                    subtitle = Self.text(count: count, dropped: dropped)
                    try? await Task.sleep(for: Self.refreshInterval)
                }
            }
    }

    static func text(count: Int, dropped: Int) -> String {
        var parts = ["\(count.formatted()) messages"]
        if dropped > 0 { parts.append("\(dropped.formatted()) dropped") }
        return parts.joined(separator: " · ")
    }
}

/// "No Messages" over the table while it is empty and not streaming. Only a change of
/// "is empty" re-renders it, not every `revision`.
private struct EmptyStateOverlay: View {
    let session: StreamSession
    @State private var isEmpty = true

    var body: some View {
        ZStack {
            if isEmpty && session.state != .streaming {
                ContentUnavailableView {
                    Text("No Messages")
                } description: {
                    Text("Streaming log messages will impact system performance.")
                } actions: {
                    Button("Start streaming") { session.start() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
        .task(id: ObjectIdentifier(session)) {
            for await empty in Observations({ [session] in
                _ = session.revision
                return session.store.count == 0
            }) where empty != isEmpty {
                isEmpty = empty
            }
        }
    }
}
