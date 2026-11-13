# BetterConsole — Design (Phase 2 MVP, with long-term architecture)

Date: 2026-11-13
Status: draft, awaiting approval

## 1. Intent

BetterConsole.app is a macOS alternative to Apple's Console.app, focused only on
**live log streaming** (no crash/spin/diagnostic reports). Streaming should feel
like Console.app; the reason the app exists is **drastically better filtering**,
which arrives after the MVP.

What frustrates the user about Console.app (drives the long-term design):

- Search queries can only be built by hand; they cannot be exported, shared, or
  edited on their own.
- The query UI is a small, non-expandable, single-line text field.
- It is hard to tell whether filter tokens combine with AND, OR, or NOT.
- Saved searches are opaque: you can't see or edit them until you apply them.
- The time format can't be changed.
- No complex logic such as `(X AND Y) when B != C`.

What Console.app does well and must be kept:

- Right-click a log line → include / exclude similar messages.
- Add, remove and reorder columns.

## 2. Scope of this phase (Phase 2 MVP)

Goals:

- Sidebar "Devices" listing every available log source: **this Mac**,
  **physical iOS/iPadOS devices** (paired, USB or network), **booted simulators**.
- Selecting a device shows its log view. Empty state matches Console.app:
  "No Messages", "Streaming log messages will impact system performance.",
  "Start streaming" button.
- Toolbar: **Start/Pause**, **Clear**, message count, **Now** (jump to latest
  and resume auto-scroll).
- Log table columns: Time, Type, Process, Subsystem, Category, Message.
- Selecting a row shows a detail pane beneath the table with the full message
  and all fields (like Console.app's lower pane).
- Sustains high throughput (target in 6.5.1) without UI stalls; when overloaded,
  drops excess messages and shows how many were dropped.
- Settings window with one setting: maximum memory for logs (default 4 GB).
- Disconnected devices stay in the sidebar with their logs and auto-resume
  streaming when they come back.

Non-goals for this phase (come later, but the MVP must not block them):

- Filters, search, saved filters, right-click include/exclude.
- Column customisation, time-format setting.
- Export of selected logs and re-opening an exported file.
- Reports of any kind (crash, spin, log reports, diagnostics) — never in scope.

Anti-goals (would make it a failure even if it "works"):

- UI that freezes or lags behind under high log volume.
- Physical-device code leaking private-framework details into the rest of the
  app, making it impossible to swap the transport later.
- A message model that drops structured fields, forcing a re-architecture when
  filters/columns arrive.

## 3. Constraints and decisions made

| Decision | Choice | Source |
|---|---|---|
| Sources | This Mac, physical iOS devices, booted simulators | user |
| Physical-device transport | Apple private `MobileDevice.framework` (same path as Console.app), **strictly isolated behind a protocol** so it can be replaced (e.g. pymobiledevice3, libimobiledevice) | user |
| Distribution | Closed source, Developer ID–signed, notarized DMG from user's website | user |
| Sandbox | **Off** (required to spawn `log`/`simctl` and load a private framework). Hardened runtime **on** | consequence |
| Minimum OS | macOS 26 | user |
| Persistence | Logs live **in memory only**. The only persistence ever: user selects logs → exports a file → the file can be reopened in the app and filtered later (future phase) | user |
| Language / UI | Swift 6 (strict concurrency), SwiftUI app shell, **AppKit `NSTableView`** for the log list | Claude's call: SwiftUI `Table` cannot sustain this insert rate |
| Storage | In-memory ring buffer behind a `LogStore` protocol (approach C) | user picked |

## 4. Approaches considered (log pipeline / storage)

- **A. In-memory ring buffer + Swift filter engine.** Simplest, fastest for
  live use, no dependencies; oldest messages are evicted when full, nothing
  survives quit.
- **B. SQLite (GRDB + FTS5), filters compiled to SQL.** Unlimited history and
  session reopening; costs a dependency, batched-write engineering at ~10k
  msg/s, and a second filter backend for live streams.
- **C. A, behind a `LogStore` protocol (chosen).** Same as A, with an
  abstraction that would allow a disk-backed store later at near-zero cost.
  Chosen because the only persistence need is explicit export/import, which a
  file format handles without a database.

## 5. Verified facts (tested on the dev machine, macOS 27 / Xcode 27.2)

- `/usr/bin/log stream --style ndjson` works **without root** and emits one JSON
  object per line with: `timestamp`, `machTimestamp`, `eventType`,
  `messageType`, `eventMessage`, `formatString`, `subsystem`, `category`,
  `processImagePath`, `processID`, `senderImagePath`, `threadID`,
  `activityIdentifier`, `parentActivityIdentifier`, `traceID`, `userID`,
  `bootUUID`, `backtrace`, persona fields, etc.
- `xcrun devicectl list devices` lists physical devices and simulators (has
  JSON output) but **has no log-streaming command**.
- `xcrun simctl spawn <udid> log stream --style ndjson` provides the same format
  for simulators.
- `MobileDevice.framework` is present at
  `/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework`.

## 6. Architecture

### 6.1 Module layout

```
BetterConsole.xcodeproj           – app target only (thin)
Packages/BetterConsoleKit/        – local Swift package, all testable logic
  Sources/LogModel/               – LogEntry, LogLevel, LogSource, JSON decoding
  Sources/LogStore/               – LogStore protocol + RingBufferLogStore
  Sources/LogTransport/           – LogTransport + DeviceDiscovery protocols,
                                    process-based transport, simctl discovery
  Sources/MobileDeviceTransport/  – ONLY place that touches MobileDevice.framework
  Sources/StreamingCore/          – StreamSession, DeviceRegistry (composition)
  Tests/…                         – one test target per module
```

`MobileDeviceTransport` depends on `LogModel` and `LogTransport` only. Nothing
else imports it except the app's composition root, which registers it. Swapping
the device transport = writing another module that conforms to the same two
protocols and changing one registration line.

### 6.2 Core model

```swift
struct LogEntry: Sendable, Identifiable {
    let id: UInt64                 // monotonically increasing per session
    let date: Date
    let machTimestamp: UInt64?
    let level: LogLevel            // default, info, debug, error, fault
    let eventType: String          // logEvent, activityCreateEvent, signpostEvent, …
    let process: String            // last path component of processImagePath
    let processImagePath: String?
    let pid: Int32?
    let threadID: UInt64?
    let subsystem: String?
    let category: String?
    let message: String
    let formatString: String?
    let senderImagePath: String?
    let activityID: UInt64?
    let parentActivityID: UInt64?
    let traceID: UInt64?
    let userID: UInt32?
    let extra: [String: JSONValue] // every other field from the source, kept verbatim
}
```

- **Every** field the source provides is kept (typed if known, otherwise in
  `extra`), so future columns and filters can address any field.
- Timestamps are stored raw; formatting is a display concern (future
  time-format setting is UI-only).
- Physical-device entries are mapped into the same struct by the device
  transport.

### 6.3 Device discovery

```swift
struct LogDevice: Sendable, Hashable, Identifiable {
    enum Kind { case thisMac, physical, simulator }
    let id: String          // "local", device UDID, or simulator UDID
    let name: String
    let kind: Kind
    let model: String?      // e.g. "iPhone 18 Pro"
    let osVersion: String?
    var isAvailable: Bool
}

protocol DeviceDiscovery: Sendable {
    func devices() -> AsyncStream<[LogDevice]>   // emits on every change
}
```

- `LocalMacDiscovery`: a single, always-available entry named after the Mac
  (`Host.current().localizedName`).
- `SimulatorDiscovery`: polls `xcrun simctl list devices booted -j` (every ~3s);
  only booted simulators are listed.
- `MobileDeviceDiscovery` (in the isolated module): `AMDeviceNotificationSubscribe`
  for connect/disconnect events.
- `DeviceRegistry` merges all discoveries. Sidebar sections: **This Mac**,
  **Devices** (physical), **Simulators**. Paired-but-unreachable physical devices
  show greyed out and can't stream (matches devicectl's "unavailable").

### 6.4 Transports

```swift
protocol LogTransport: Sendable {
    func supports(_ device: LogDevice) -> Bool
    /// Starts streaming; cancelling the consuming Task stops the underlying stream.
    func stream(from device: LogDevice) -> AsyncThrowingStream<[LogEntry], Error>
}
```

- `ProcessLogTransport` (Mac + simulators):
  - Mac: `/usr/bin/log stream --style ndjson --level debug`
  - Simulator: `/usr/bin/xcrun simctl spawn <udid> log stream --style ndjson --level debug`
  - Reads stdout off the main thread, splits lines, skips non-JSON lines (`log`
    prints a "Filtering the log data…" header), decodes, and emits **batches**
    (flush every ~50 ms or 1,000 entries, whichever first).
  - Terminates the child process on cancellation and on app quit (no orphans).
- `MobileDeviceTransport` (physical devices):
  - Loads `MobileDevice.framework` at runtime with `dlopen`/`dlsym`; no link-time
    dependency. If loading fails, physical devices simply don't appear and the
    rest of the app works.
  - Connects, starts a session, and opens the `com.apple.os_trace_relay`
    service; sends the `StartActivity` request; decodes the binary os_trace
    stream into `LogEntry` values (pymobiledevice3's `os_trace` implementation
    is the reference for the wire format).
  - **Highest-risk part of the project → first task is a throwaway spike** to
    prove that a Developer-ID-signed, hardened-runtime app can open
    `os_trace_relay` and decode entries from a device without Apple-only
    entitlements. (user decision)
    - **Pass = USB on iOS 26+.** If that works, physical devices ship in the MVP.
    - Wi-Fi and iOS < 26 are **nice-to-have**: included only if they work with
      the same code path; otherwise they're listed as known gaps, not blockers.
    - **Fail** (USB on iOS 26+ doesn't work): the MVP ships with Mac +
      simulators, `MobileDeviceTransport` is dropped from this phase, and the
      transport choice goes back to the user.

### 6.5 Store and memory budget

```swift
protocol LogStore: AnyObject {
    var count: Int { get }
    var estimatedBytes: Int { get }
    subscript(index: Int) -> LogEntry { get }
    func append(contentsOf: [LogEntry])
    func removeOldest(_ n: Int)
    func removeAll()
}
```

- `RingBufferLogStore` per device session; no fixed per-device cap.
- **Global memory budget across all sessions** (user decision): default
  **4 GB**, changeable in the app's **Settings window** (the only setting in
  the MVP). A `MemoryBudget` coordinator tracks the estimated bytes of every
  store; when the total exceeds the budget it evicts the **oldest entries
  across all sessions** (by timestamp) until under budget. Lowering the setting
  takes effect immediately.
- Per-entry size is an estimate (string UTF-8 lengths + fixed overhead); the
  builder calibrates the constant against real measurements.
- Main-actor isolated; batches arrive already decoded off-main, so main-thread
  work per batch is an append plus one table update.

### 6.5.1 Throughput and overload (user decision: drop + counter)

- Target (Claude's call): sustain **≥ 20,000 msg/s per Mac stream** decoded,
  stored and displayed with no UI stall (main thread never blocked > 16 ms).
- Pipeline: reader → decoder (off-main) → bounded queue → main-actor batch
  apply. The reader must never block on the UI, so `log` itself never backs up.
- When the bounded queue is full, **excess entries are dropped** and counted.
  The session exposes `droppedCount`; the toolbar shows "N dropped" next to the
  message count whenever it's > 0. Clear resets it.
- Decoder choice (`JSONDecoder` vs. a hand-written/`JSONSerialization` path) is
  the builder's, driven by measuring against the target.

### 6.6 Streaming session and UI

- `StreamSession` (one per device, `@Observable`, `@MainActor`): state
  `idle | streaming | paused | failed(Error)`, owns the store and the streaming
  Task.
  - **Start** → begins the transport stream, appends to the existing store.
  - **Pause** → cancels the transport stream (stops the child process / relay);
    already-received messages stay. Start resumes appending.
  - **Clear** → empties the store; streaming state unchanged.
- Sessions are **keyed by device ID** and persist while the app runs;
  **switching devices in the sidebar does not stop other streams** (Claude's
  call: lets you compare a phone and a simulator by switching).
- **Disconnect / reconnect** (user decision: auto-resume):
  - When a device disappears (simulator shut down, phone unplugged), its
    sidebar row **stays, greyed out**, and its logs remain browsable. The
    session moves to `disconnected` (new state) and the log view shows a banner.
  - `DeviceRegistry` therefore merges live discovery with known sessions: a row
    exists if the device is discovered **or** has a session.
  - When the same device ID is discovered again, a session that was
    `streaming` at disconnect time **restarts automatically**, appending to the
    same store. A session that was paused/idle stays paused.
  - A row with no logs whose device disappears is removed (nothing to keep).
- Log table: `NSTableView` (view-based, fixed row height, cell reuse) wrapped
  in `NSViewRepresentable`. Inserts are applied in batches; at most ~10 table
  updates per second.
  - **Auto-scroll**: when scrolled to the bottom, follow new rows; when the user
    scrolls up, stop following. **Now** scrolls to bottom and re-enables follow.
- Columns: Time (`HH:mm:ss.SSSSSS`, local time zone), Type (coloured dot:
  grey default/info/debug, yellow error, red fault), Process, Subsystem,
  Category, Message (single line, truncated). Column widths are resizable;
  reorder/add/remove is a later phase but the table must be built from a
  column-definition list (not hard-coded cells) so it can be added cheaply.
- Detail pane: shows the selected entry's full message and all fields
  (including `extra`), selectable text.
- Window layout mirrors Console.app: `NavigationSplitView` with the devices
  sidebar and the log view (table on top, detail pane below, resizable split).
  The Reports section from Console.app is intentionally absent.

### 6.7 Errors

- Device disconnect: handled as in 6.6 (`disconnected`, auto-resume).
- Other transport failures (process exits unexpectedly while the device is
  still present, framework missing, relay error): session → `failed`, inline
  banner with the reason and a "Retry" button.
- `<private>` redaction is expected behaviour (same as Console.app), not an
  error.

## 7. Future phases (designed for, not built now)

- **Filters as an expression tree**: groups (AND / OR), NOT, conditions on any
  `LogEntry` field (equals, contains, prefix, regex, …), and conditional rules
  (`(X AND Y) when B != C`). Serialised as JSON → export/share/edit
  independently; shown both as a visual tree builder and as an expandable text
  form kept in sync. Saved filters are visible and editable in a library.
- Right-click on a row → include/exclude "similar" (same process, subsystem,
  category, …) adds a condition to the active filter.
- Column customisation (add/remove/reorder) and time-format setting.
- **Export selected logs** to a file (format TBD, JSON-lines of `LogEntry`
  with all fields is the default candidate) and **open that file** in the app
  as a read-only source with full filtering.

## 8. Testing

- Unit tests (Swift Testing) in `BetterConsoleKit`:
  - NDJSON decoding from captured real fixtures (Mac + simulator), including the
    non-JSON header line, unknown fields → `extra`, every `messageType`.
  - Line splitting across arbitrary chunk boundaries.
  - Batching (time- and size-based flushes).
  - Ring buffer eviction and indexing; global memory budget eviction across
    several stores (oldest-first), and lowering the budget at runtime.
  - Overload: bounded queue drops and counts; Clear resets the counter.
  - Disconnect → reconnect: streaming session auto-resumes into the same store;
    paused session stays paused; row with no logs disappears.
  - `simctl list -j` parsing.
  - `StreamSession` state transitions (start → pause → start, clear while
    streaming, transport failure) with a fake `LogTransport`.
  - os_trace binary decoding from captured byte fixtures (captured during the
    spike).
- Manual verification: stream this Mac, a booted simulator, and PhoneVac;
  throughput check while a heavy logger runs.

## 9. Left to the builder

- Exact batching intervals, bounded-queue size, and the per-entry size
  estimate (measure, then tune).
- Bundle identifier, app icon, signing team configuration.
- Xcode project mechanics (file-system-synchronised groups recommended).
- Exact os_trace wire-format decoding details (follow pymobiledevice3 as
  reference).
