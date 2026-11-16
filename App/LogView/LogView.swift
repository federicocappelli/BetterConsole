import SwiftUI
import BCFilter
import BCModel
import BCStreaming

/// The log pane for one session: toolbar, banners, filter bar, empty state, the table and the
/// detail pane.
struct LogView: View {
    let session: StreamSession
    let library: FilterLibrary
    let workspace: FilterWorkspace
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
            FilterBar(session: session, library: library, workspace: workspace)
            Divider()
            ZStack {
                LogTableView(
                    session: session, workspace: workspace, nowRequest: nowRequest,
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

/// Sets the window subtitle (message, matching and dropped counts), at most `refreshInterval`
/// apart: a subtitle change re-lays out the window title bar (several ms), and `revision`
/// changes up to 10 times a second.
private struct SessionSubtitle: View {
    static let refreshInterval: Duration = .milliseconds(250)

    let session: StreamSession
    @State private var subtitle = ""

    var body: some View {
        Color.clear
            .navigationSubtitle(subtitle)
            .task(id: ObjectIdentifier(session)) {
                // `Observations` coalesces changes made while this loop sleeps.
                for await text in Observations({ [session] in
                    _ = session.revision
                    return Self.text(
                        shown: session.filter != nil ? session.rows.count : nil,
                        count: session.store.count, dropped: session.droppedCount)
                }) {
                    subtitle = text
                    try? await Task.sleep(for: Self.refreshInterval)
                }
            }
    }

    /// `shown`: the number of matching messages while a filter is set, else nil.
    static func text(shown: Int?, count: Int, dropped: Int) -> String {
        var parts = [
            shown.map { "\($0.formatted()) of \(count.formatted()) messages" }
                ?? "\(count.formatted()) messages"
        ]
        if dropped > 0 { parts.append("\(dropped.formatted()) dropped") }
        return parts.joined(separator: " · ")
    }
}

/// "No Messages" over the table while the session has no messages and is not streaming;
/// "No Matching Messages" while it has some but none matches the filter (and the rescan is
/// done). Only a change of which one applies re-renders it, not every `revision`.
private struct EmptyStateOverlay: View {
    enum Content: Equatable {
        case none, noMessages, noMatches
    }

    let session: StreamSession
    @State private var content = Content.noMessages

    var body: some View {
        ZStack {
            switch content {
            case .noMessages where session.state != .streaming:
                ContentUnavailableView {
                    Text("No Messages")
                } description: {
                    Text("Streaming log messages will impact system performance.")
                } actions: {
                    Button("Start streaming") { session.start() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            case .noMatches:
                ContentUnavailableView {
                    Text("No Matching Messages")
                } description: {
                    Text("No messages match the current filter.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            case .none, .noMessages:
                EmptyView()
            }
        }
        .task(id: ObjectIdentifier(session)) {
            for await next in Observations({ [session] in
                _ = session.revision
                if session.store.count == 0 { return Content.noMessages }
                if session.filter != nil, session.rows.count == 0, !session.isFiltering {
                    return Content.noMatches
                }
                return Content.none
            }) where next != content {
                content = next
            }
        }
    }
}
