import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BCFilter
import BCModel
import BCStreaming

/// The log pane for one session: toolbar, banners, filter bar, empty state, the table and the
/// detail pane. For an opened file (a finite session) there are no streaming buttons; a
/// progress banner shows while it loads and a banner once the memory limit evicted messages.
struct LogView: View {
    let session: StreamSession
    let library: FilterLibrary
    let workspace: FilterWorkspace
    /// An opened file's share read so far (0...1), polled while it loads.
    var loadProgress: (@MainActor () -> Double)?
    /// Bumped by the Now button; the table scrolls to the bottom and resumes following.
    @State private var nowRequest = 0
    @State private var detail = LogDetailView.Content.none
    /// Whether the list shows any row (enables File ▸ Save Logs…); changes only when that does.
    @State private var hasRows = false

    // `session.revision` changes up to 10 times a second, so only small child views read it
    // (subtitle, empty state); the table observes it itself. This body, with the toolbar,
    // re-renders on state changes only.
    var body: some View {
        VStack(spacing: 0) {
            if let banner {
                banner
                Divider()
            }
            if session.isFinite {
                FileBanners(session: session, loadProgress: loadProgress)
            }
            FilterBar(session: session, library: library, workspace: workspace)
            Divider()
            ZStack {
                LogTableView(
                    session: session, workspace: workspace, nowRequest: nowRequest,
                    onSelect: { detail = $0 },
                    detail: LogDetailView(content: detail))
                EmptyStateOverlay(session: session)
            }
        }
        .background { SessionSubtitle(session: session) }
        .focusedSceneValue(
            \.saveLogsTarget,
            session.isFinite ? nil : SaveLogsTarget(session: session, hasRows: hasRows))
        .task(id: ObjectIdentifier(session)) {
            for await next in Observations({ [session] in
                _ = session.revision
                return session.rows.count > 0
            }) where next != hasRows {
                hasRows = next
            }
        }
        .navigationTitle(session.device.name)
        .toolbar {
            if !session.isFinite { streamingButtons }
        }
    }

    @ToolbarContentBuilder
    private var streamingButtons: some ToolbarContent {
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
            // A file can't be retried: reading it again would add what was read twice.
            if session.isFinite {
                Banner(symbol: "exclamationmark.triangle.fill", message: message, action: nil)
            } else {
                Banner(
                    symbol: "exclamationmark.triangle.fill", message: message,
                    action: ("Retry", { session.retry() }))
            }
        case .idle, .streaming, .paused, .finished:
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

/// An opened file's banners: "Loading… 45%" while it is read, then, once the memory budget
/// evicted its oldest messages, how many fit. Its own view so progress re-renders only this.
private struct FileBanners: View {
    let session: StreamSession
    let loadProgress: (@MainActor () -> Double)?
    @State private var progress: Double?
    @State private var kept: Int?

    var body: some View {
        VStack(spacing: 0) {
            if let progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 120)
                    Text(LogFileText.loading(progress: progress))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
            }
            if let kept {
                HStack(spacing: 8) {
                    Image(systemName: "memorychip").foregroundStyle(.secondary)
                    Text(LogFileText.memoryLimit(kept: kept))
                    Spacer()
                    SettingsLink { Text("Settings…") }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
                Divider()
            }
        }
        .task(id: ObjectIdentifier(session)) {
            // Polled: the share read lives in the transport, off the main actor.
            while !Task.isCancelled {
                progress = session.state == .streaming ? (loadProgress?() ?? 0) : nil
                if session.state != .streaming, session.state != .idle { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .task(id: ObjectIdentifier(session)) {
            for await next in Observations({ [session] in
                _ = session.revision
                return session.store.removedCount > 0 ? session.store.count : nil
            }) where next != kept {
                kept = next
            }
        }
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
            case .noMessages where session.isFinite && session.state == .finished:
                ContentUnavailableView {
                    Text("No Messages")
                } description: {
                    Text("The file has no log messages.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            case .noMessages where !session.isFinite && session.state != .streaming:
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

// MARK: - Save Logs

/// The session File ▸ Save Logs… acts on: the device selected in the sidebar.
struct SaveLogsTarget {
    let session: StreamSession
    let hasRows: Bool
}

extension FocusedValues {
    @Entry var saveLogsTarget: SaveLogsTarget?
}

/// File ▸ Save Logs… (⌘S): enabled while the main window's list shows a row. Disabled while an
/// opened file's window is key — saving a file's logs again makes no sense.
struct SaveLogsCommand: View {
    @FocusedValue(\.saveLogsTarget) private var focused

    /// File windows are AppKit windows, so the focused value may still be the main window's
    /// while one is key: `KeyLogFileWindow` says when one is.
    private var target: SaveLogsTarget? { KeyLogFileWindow.shared.isKey ? nil : focused }

    var body: some View {
        Button("Save Logs…") {
            if let target { LogSaver.save(target.session) }
        }
        .keyboardShortcut("s")
        .disabled(target?.hasRows != true)
    }
}

/// Saves every row the list shows (the filter applied) to a `.log` file: the rows are
/// snapshotted when Save is chosen, gathered from the store in short main-actor chunks
/// (rows evicted meanwhile are skipped), and the text is built and written off the main actor.
@MainActor
enum LogSaver {
    static func save(_ session: StreamSession) {
        let snapshot = session.rows.snapshot()
        guard snapshot.count > 0 else { return }
        let panel = NSSavePanel()
        panel.title = "Save Logs"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.log]
        panel.nameFieldStringValue = RowCopy.logFileName(deviceName: session.device.name, date: .now)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let pieces = await session.mapEntries(of: snapshot, { RowCopy.saveLines(for: $0) })
            else { return }
            do {
                try await write(pieces, to: url)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The logs couldn't be saved: \(error.localizedDescription)"
                alert.runModal()
            }
        }
    }

    @concurrent
    private nonisolated static func write(_ pieces: [String], to url: URL) async throws {
        try RowCopy.logFileData(pieces).write(to: url, options: .atomic)
    }
}

