# BetterConsole MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS app that lists this Mac, booted simulators and USB-connected iOS 26+ devices, and streams each one's unified log into a fast table, like Console.app without filters.

**Architecture:** All logic lives in a local Swift package (`Packages/BetterConsoleKit`) split into small modules; the app target is a thin SwiftUI shell with an AppKit `NSTableView`. Mac/simulator logs come from spawning `log stream --style ndjson`; physical devices go through an isolated module that `dlopen`s Apple's private `MobileDevice.framework`. Entries flow reader → decoder (off-main) → bounded queue (drops + counts) → main-actor drain → in-memory ring buffers under one global memory budget.

**Tech Stack:** Swift 6.4 (strict concurrency), SwiftUI + AppKit, Swift Testing, XcodeGen 2.46 (`/opt/homebrew/bin/xcodegen`), Xcode 27.2.

**Spec:** `docs/superpowers/specs/2026-11-13-betterconsole-mvp-design.md`

## Global Constraints

- Deployment target: **macOS 26.0**. Swift language mode 6, complete strict concurrency.
- App Sandbox **off**; Hardened Runtime **on**; distribution Developer ID + notarized DMG.
- No third-party runtime dependencies. XcodeGen is a dev-time tool only.
- `MobileDevice.framework` is touched **only** inside module `BCMobileDevice`; nothing imports that module except the app's composition root (`AppEnvironment.swift`).
- Logs are in memory only; no disk persistence in this phase.
- Global memory budget default **4 GB** (`4 * 1024 * 1024 * 1024` bytes), user-changeable in Settings; eviction is oldest-first across all sessions.
- Overload: drop excess, expose `droppedCount`, toolbar shows "N dropped" when > 0; Clear resets it.
- Throughput target: ≥ **20,000 msg/s** per Mac stream, main thread never blocked > 16 ms.
- Empty-state copy (exact): title "No Messages", subtitle "Streaming log messages will impact system performance.", button "Start streaming".
- Time column format: `HH:mm:ss.SSSSSS`, local time zone.
- Type dot colours: default/info/debug grey, error yellow, fault red.
- Module names use a `BC` prefix (spec §6.1 names them LogModel/LogStore/…; renamed so module names never collide with type names like `LogStore`).

## Review Focus

1. **Timestamp precision:** `log` emits microseconds (`2026-11-13 15:55:22.273495+0000`); `DateFormatter` truncates to ms. Expect µs preserved → test in Task 1.
2. **App quit / session teardown while streaming:** no orphaned `log` or `simctl` child processes → test in Task 4.
3. **Child process dies on its own** (killed, Mac sleep, simulator crash) while the device is still discovered: session must go to `failed` with Retry, never hang in `streaming` → test in Task 6.
4. **Device flapping** (disappears and reappears quickly, or reappears twice): auto-resume must never start two streams for one session → test in Task 6.
5. **Malformed or non-UTF-8 lines** in the stream (header line, truncated last line on cancel): skipped without crashing or stalling the stream → test in Task 1 and Task 2.

---

## File Structure

```
project.yml                                   XcodeGen spec (source of truth for the .xcodeproj)
BetterConsole.xcodeproj/                      generated, committed
App/
  BetterConsoleApp.swift                      @main, WindowGroup + Settings scenes
  AppEnvironment.swift                        composition root: registers transports/discoveries
  Sidebar/DeviceSidebar.swift                 sidebar sections
  LogView/LogView.swift                       toolbar, empty state, banner, split table/detail
  LogView/LogTableView.swift                  NSViewRepresentable around NSTableView
  LogView/LogColumns.swift                    column definitions
  LogView/LogDetailView.swift                 selected-entry pane
  Settings/SettingsView.swift                 memory budget setting
  BetterConsole.entitlements                  sandbox off
Packages/BetterConsoleKit/
  Package.swift
  Sources/BCModel/        LogLevel.swift, LogEntry.swift, JSONValue.swift, LogEntryDecoder.swift, LogDevice.swift
  Sources/BCStore/        LogStore.swift, RingBufferLogStore.swift, MemoryBudget.swift
  Sources/BCTransport/    LogTransport.swift, DeviceDiscovery.swift, LineSplitter.swift,
                          ProcessLogTransport.swift, LocalMacDiscovery.swift, SimulatorDiscovery.swift
  Sources/BCStreaming/    BoundedBatchQueue.swift, StreamSession.swift, SessionRegistry.swift
  Sources/BCMobileDevice/ MobileDeviceAPI.swift, MobileDeviceDiscovery.swift,
                          OSTraceDecoder.swift, MobileDeviceLogTransport.swift
  Tests/BCModelTests/ BCStoreTests/ BCTransportTests/ BCStreamingTests/ BCMobileDeviceTests/
  Tests/**/Fixtures/                          captured real output
Spikes/OSTraceSpike/                          throwaway (Task 0), deleted in Task 10
```

Test command used throughout: `swift test --package-path Packages/BetterConsoleKit` (add `--filter <Suite>` per task).

---

### Task 0: Spike — physical device log relay (throwaway)

Decides whether Task 10 is in the MVP. Not TDD; no production code.

**Files:**
- Create: `Spikes/OSTraceSpike/Package.swift`, `Spikes/OSTraceSpike/Sources/main.swift`
- Create: `Spikes/OSTraceSpike/RESULT.md`
- Create (output): `Packages/BetterConsoleKit/Tests/BCMobileDeviceTests/Fixtures/ostrace-*.bin` (raw captured bytes, at least one fixture per message level seen)

- [ ] **Step 1:** Write a CLI that `dlopen`s `/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice`, subscribes with `AMDeviceNotificationSubscribe`, and for the first attached device: `AMDeviceConnect` → `AMDeviceIsPaired`/`AMDeviceValidatePairing` → `AMDeviceStartSession` → `AMDeviceSecureStartService(device, "com.apple.os_trace_relay", nil, &conn)`.
- [ ] **Step 2:** Send the plist request `{Request: "StartActivity", MessageFilter: 65535, Pid: -1, StreamFlags: 60}` (wire format reference: pymobiledevice3 `services/os_trace.py`), read the status reply, then dump raw entry frames to fixture files and print decoded pid/time/level/process/subsystem/category/message.
- [ ] **Step 3:** Codesign the binary with the Developer ID identity and hardened runtime (`codesign -s "Developer ID Application" -o runtime`), run against PhoneVac over **USB**. Then try Wi-Fi (unplugged, same network).
- [ ] **Step 4:** Write `RESULT.md`: pass/fail for USB on iOS 26+, Wi-Fi result, iOS version tested, any entitlement errors, and the frame layout actually observed.
- [ ] **Step 5: Gate.** USB on iOS 26+ works → Task 10 is in scope. Fails → skip Task 10, stop and report to the user (spec §6.4).
- [ ] **Step 6:** Commit `git add Spikes Packages/BetterConsoleKit/Tests/BCMobileDeviceTests/Fixtures && git commit -m "spike: os_trace_relay over MobileDevice"`

---

### Task 1: Package scaffold + log model + NDJSON decoding

**Files:**
- Create: `Packages/BetterConsoleKit/Package.swift` (platforms `.macOS("26.0")`, five library targets + five test targets, test targets declare `resources: [.copy("Fixtures")]`)
- Create: `Sources/BCModel/{LogLevel,LogEntry,JSONValue,LogEntryDecoder,LogDevice}.swift`
- Test: `Tests/BCModelTests/LogEntryDecoderTests.swift`, fixtures `Tests/BCModelTests/Fixtures/mac.ndjson` (capture: `timeout 3 log stream --style ndjson --level debug > mac.ndjson`, keep header line, trim to ~200 lines including at least one each of default/info/debug/error/fault and an activity event), `simulator.ndjson` (same via `xcrun simctl spawn <booted udid> log stream …`)

**Interfaces:**
- Produces:
  - `public enum LogLevel: String, Sendable { case `default` = "Default", info = "Info", debug = "Debug", error = "Error", fault = "Fault" }` (raw values are `messageType` strings from `log`; unknown → `.default`)
  - `public enum JSONValue: Sendable, Hashable { string, number(Double), bool, null, array([JSONValue]), object([String: JSONValue]) }`
  - `public struct LogEntry: Sendable, Identifiable` with exactly the fields in spec §6.2 (`id: UInt64`, `date`, `machTimestamp`, `level`, `eventType`, `process`, `processImagePath`, `pid`, `threadID`, `subsystem`, `category`, `message`, `formatString`, `senderImagePath`, `activityID`, `parentActivityID`, `traceID`, `userID`, `extra`) plus `public var estimatedBytes: Int` (sum of UTF-8 lengths of all strings + `extra` serialized length + 160 fixed overhead).
  - `public struct LogEntryDecoder { public init(); public mutating func decode(line: Data) -> LogEntry? }` — assigns increasing `id` starting at 1; returns nil for non-JSON / non-object lines.
  - `public struct LogDevice: Sendable, Hashable, Identifiable { public enum Kind: Sendable { case thisMac, physical, simulator }; id, name, kind, model: String?, osVersion: String? }` (availability is tracked by `SessionRegistry`, not stored here).

- [ ] **Step 1: Write failing tests** (`@Suite struct LogEntryDecoderTests`):
  - `decodesAllMacFixtureLines`: every JSON line of `mac.ndjson` decodes; header line returns nil.
  - `parsesMicrosecondTimestamp`: line with `"timestamp":"2026-11-13 15:55:22.273495+0000"` → `date.timeIntervalSince1970` == `1794585322.273495` within `1e-7`.
  - `mapsKnownFields`: `processImagePath "/Users/x/.bun/bin/bun"` → `process == "bun"`; `processID 21345` → `pid == 21345`; `eventMessage` → `message`; `messageType "Fault"` → `.fault`.
  - `keepsUnknownFieldsInExtra`: `launchPersonaName`, `backtrace` end up in `extra` unchanged.
  - `emptyStringsBecomeNil`: `"subsystem":""` → `subsystem == nil`.
  - `skipsMalformedLines`: `Data("{\"trunc".utf8)`, `Data([0xFF,0xFE])`, `Data("[1,2]".utf8)` → nil, and the next valid line still gets the next id.
  - `idsIncrease`: three valid lines → ids 1, 2, 3.
- [ ] **Step 2:** Run `swift test --package-path Packages/BetterConsoleKit --filter LogEntryDecoderTests` → FAIL (types missing).
- [ ] **Step 3:** Implement. Decode with `JSONSerialization` into `[String: Any]` then map (measure against `JSONDecoder` later in Task 11 only if the throughput target fails). Parse timestamp manually: fixed layout `yyyy-MM-dd HH:mm:ss.ffffff±hhmm`, build seconds via `DateComponents` in the parsed offset + fractional µs as Double.
- [ ] **Step 4:** Run tests → PASS.
- [ ] **Step 5:** Add `.gitignore` (`.build/`, `DerivedData/`, `*.xcuserstate`, `xcuserdata/`). Commit: `git commit -m "feat(model): LogEntry and NDJSON decoder"`

---

### Task 2: Line splitting

**Files:**
- Create: `Sources/BCTransport/LineSplitter.swift`
- Test: `Tests/BCTransportTests/LineSplitterTests.swift`

**Interfaces:**
- Produces: `public struct LineSplitter { public init(); public mutating func feed(_ chunk: Data) -> [Data]; public mutating func finish() -> Data? }` — returns complete lines without the `\n`; `finish()` returns a trailing partial line (or nil).

- [ ] **Step 1: Failing tests:** `splitsAcrossChunkBoundaries` (feed `"ab"`, `"c\nde"`, `"f\n"` → `["abc"]`, then `["def"]`); `multipleLinesInOneChunk`; `emptyLinesDropped` (`"\n\n"` → `[]`); `finishReturnsPartial` (`"xyz"` then `finish()` → `"xyz"`); `byteExactAcrossUTF8Split` (a 4-byte emoji split across two chunks is reassembled byte-for-byte).
- [ ] **Step 2:** Run `--filter LineSplitterTests` → FAIL.
- [ ] **Step 3:** Implement with a single `Data` buffer, scanning only newly appended bytes for `0x0A`.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(transport): line splitter`.

---

### Task 3: Store + global memory budget

**Files:**
- Create: `Sources/BCStore/{LogStore,RingBufferLogStore,MemoryBudget}.swift`
- Test: `Tests/BCStoreTests/{RingBufferLogStoreTests,MemoryBudgetTests}.swift`

**Interfaces:**
- Consumes: `LogEntry`, `LogEntry.estimatedBytes` (Task 1).
- Produces:
  - `@MainActor public protocol LogStore: AnyObject { var count: Int { get }; var estimatedBytes: Int { get }; var oldestDate: Date? { get }; subscript(index: Int) -> LogEntry { get }; func append(contentsOf: [LogEntry]); func removeOldest(_ n: Int); func removeAll() }` (spec §6.5 plus `oldestDate`, needed for cross-session oldest-first eviction).
  - `@MainActor public final class RingBufferLogStore: LogStore` — growable circular buffer, index 0 = oldest, O(1) `removeOldest`.
  - `@MainActor public final class MemoryBudget { public static let defaultLimit = 4 * 1024 * 1024 * 1024; public var limitBytes: Int { didSet { enforce() } }; public init(limitBytes: Int = defaultLimit); public func register(_ store: LogStore); public func unregister(_ store: LogStore); public func enforce() }` — holds stores weakly; `enforce()` repeatedly removes entries from whichever store has the oldest `oldestDate` until total ≤ limit (remove in chunks of up to 1,000 entries whose dates are older than the next store's oldest, to stay fast).

- [ ] **Step 1: Failing tests:**
  - Ring: `appendAndIndexInOrder`, `removeOldestShiftsIndices` (append 1…10, remove 3 → `[0].id == 4`, `count == 7`), `bytesTrackAppendAndRemove`, `removeAllResets` (`count == 0`, `estimatedBytes == 0`, `oldestDate == nil`), `wrapsAroundAfterRemovals` (append 5, remove 3, append 5 → ids in order 4…13 region correct).
  - Budget: `evictsOldestAcrossStores` (store A dates t=1,3,5; store B t=2,4,6; limit = bytes of 4 entries → A keeps 5, B keeps 4,6), `loweringLimitEvictsImmediately`, `underLimitNoEviction`, `unregisteredStoreIgnored`.
- [ ] **Step 2:** Run `--filter "RingBufferLogStoreTests|MemoryBudgetTests"` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(store): ring buffer and global memory budget`.

---

### Task 4: Transport + discovery protocols, process transport

**Files:**
- Create: `Sources/BCTransport/{LogTransport,DeviceDiscovery,ProcessLogTransport}.swift`
- Test: `Tests/BCTransportTests/ProcessLogTransportTests.swift`, fixture script `Tests/BCTransportTests/Fixtures/emit.sh` (prints the header line, then `$1` copies of a fixture JSON line, then optionally sleeps forever if `$2 == hang`)

**Interfaces:**
- Consumes: `LineSplitter`, `LogEntryDecoder`, `LogDevice`.
- Produces:
  - `public protocol LogTransport: Sendable { func supports(_ device: LogDevice) -> Bool; func stream(from device: LogDevice) -> AsyncThrowingStream<[LogEntry], Error> }` (spec §6.4; cancelling the consuming task stops the source).
  - `public protocol DeviceDiscovery: Sendable { func devices() -> AsyncStream<[LogDevice]> }`
  - `public struct ProcessLogTransport: LogTransport { public init(commandFor: @Sendable (LogDevice) -> (executable: URL, arguments: [String])? = ProcessLogTransport.defaultCommand) ; public static func defaultCommand(_ d: LogDevice) -> (URL, [String])? }`
    - `.thisMac` → `/usr/bin/log`, `["stream","--style","ndjson","--level","debug"]`
    - `.simulator` → `/usr/bin/xcrun`, `["simctl","spawn",udid,"log","stream","--style","ndjson","--level","debug"]`
    - `.physical` → nil (`supports` false)
  - `public enum TransportError: Error, Equatable { case processExited(status: Int32), launchFailed(String) }`
  - Batching: yield when 1,000 entries accumulated or 50 ms since the first unflushed entry. Reading via `FileHandle.readabilityHandler` on a background queue (never waits on main).
  - Child process runs in its own process group; on cancellation send SIGTERM, then SIGKILL after 1 s. Register every live child in a process-wide `ChildProcessRegistry` with `terminateAll()` (called from app termination in Task 8).
  - Process exit not caused by cancellation → stream finishes throwing `.processExited(status:)`.

- [ ] **Step 1: Failing tests:**
  - `emitsAllEntriesInBatches`: `emit.sh 2500` → total 2,500 entries, ≥ 3 batches, header skipped.
  - `cancellationKillsChild`: `emit.sh 1 hang`; read first batch, cancel task; within 2 s `kill(pid, 0)` fails with `ESRCH`.
  - `terminateAllKillsChildren`: start two hanging streams, `ChildProcessRegistry.shared.terminateAll()`, both pids gone.
  - `unexpectedExitThrows`: `emit.sh 3` exits 0 by itself → stream throws `TransportError.processExited(status: 0)` after delivering 3 entries.
  - `defaultCommands`: exact executable/arguments above for mac and simulator; nil for physical.
- [ ] **Step 2:** Run `--filter ProcessLogTransportTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(transport): process-based log transport`.

---

### Task 5: Local Mac + simulator discovery

**Files:**
- Create: `Sources/BCTransport/{LocalMacDiscovery,SimulatorDiscovery}.swift`
- Test: `Tests/BCTransportTests/SimulatorDiscoveryTests.swift`, fixture `simctl-booted.json` (capture `xcrun simctl list devices booted -j` with ≥ 1 booted sim; hand-add a second runtime entry)

**Interfaces:**
- Produces:
  - `public struct LocalMacDiscovery: DeviceDiscovery` — emits once `[LogDevice(id: "local", name: Host.current().localizedName ?? "This Mac", kind: .thisMac, model: nil, osVersion: ProcessInfo.processInfo.operatingSystemVersionString)]`.
  - `public struct SimulatorDiscovery: DeviceDiscovery { public init(interval: Duration = .seconds(3), runner: @Sendable () async throws -> Data = SimulatorDiscovery.runSimctl) ; public static func parse(_ json: Data) throws -> [LogDevice] }` — emits only when the list changes. `model` = device type name, `osVersion` from runtime key (`com.apple.CoreSimulator.SimRuntime.iOS-27-2` → `"iOS 27.2"`). Runner failure (Xcode missing) → emits `[]`, keeps polling.

- [ ] **Step 1: Failing tests:** `parsesBootedDevices` (ids, names, osVersion `"iOS 27.2"`), `emitsOnlyOnChange` (runner returns A, A, B → stream yields A, B), `runnerFailureEmitsEmpty`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(transport): mac and simulator discovery`.

---

### Task 6: Streaming core — bounded queue, sessions, registry

**Files:**
- Create: `Sources/BCStreaming/{BoundedBatchQueue,StreamSession,SessionRegistry}.swift`
- Test: `Tests/BCStreamingTests/{BoundedBatchQueueTests,StreamSessionTests,SessionRegistryTests}.swift`, with `FakeTransport` (test-controlled continuation per `stream(from:)` call, records call count) and `FakeDiscovery` (test pushes device lists).

**Interfaces:**
- Consumes: `LogTransport`, `DeviceDiscovery`, `LogDevice`, `LogStore`/`RingBufferLogStore`, `MemoryBudget`.
- Produces:
  - `public final class BoundedBatchQueue: Sendable { public init(capacity: Int = 200_000); public func push(_ entries: [LogEntry]); public func drain() -> (entries: [LogEntry], dropped: Int) }` — `Mutex`-protected; when full, the incoming excess is dropped and counted; `drain` returns and resets the dropped-since-last-drain count.
  - `@MainActor @Observable public final class StreamSession { public enum State: Equatable { case idle, streaming, paused, disconnected(wasStreaming: Bool), failed(String) }; public let device: LogDevice; public private(set) var state: State; public let store: LogStore; public private(set) var droppedCount: Int; public private(set) var revision: Int /* bumps on every drain that changed the store */; public func start(); public func pause(); public func clear(); public func retry() }`
    - Init: `init(device:transport:budget:drainInterval: Duration = .milliseconds(100))`.
    - `start()` from idle/paused/failed: launches a detached task consuming the transport stream and pushing to the queue; main-actor drain loop every `drainInterval` appends to store, adds to `droppedCount`, calls `budget.enforce()`. No-op if already streaming.
    - Stream throws while device still present → `failed(String(describing: error))`. `retry()` == `start()` from failed.
    - `clear()` → `store.removeAll()`, `droppedCount = 0`, state unchanged.
  - `@MainActor @Observable public final class SessionRegistry { public init(discoveries: [any DeviceDiscovery], transports: [any LogTransport], budget: MemoryBudget); public private(set) var rows: [Row]; public func session(for id: LogDevice.ID) -> StreamSession?; public func run() async }`
    - `public struct Row: Identifiable { public let device: LogDevice; public let isAvailable: Bool }`, sorted: thisMac, physical (by name), simulator (by name).
    - Row exists if the device is discovered **or** its session's store is non-empty. Session created lazily on first `session(for:)`; keyed by device id.
    - Device disappears: session in `.streaming` → cancel stream, `.disconnected(wasStreaming: true)`; other states → `.disconnected(wasStreaming: false)`; sessions with empty store and their rows are removed.
    - Device reappears: `.disconnected(wasStreaming: true)` → `start()` exactly once; `.disconnected(false)` → `.paused`.
    - Disconnect wins over failure: if the stream throws because the device vanished, the next discovery update overrides `failed` with `disconnected(wasStreaming: true)` when the session was streaming at the time of the error.

- [ ] **Step 1: Failing tests:**
  - Queue: `dropsExcessAndCounts` (capacity 10, push 15 → drain 10 entries, dropped 5; next drain dropped 0), `concurrentPushesAreSafe`.
  - Session: `startStreamsIntoStore`, `pauseStopsAndKeepsEntries` (FakeTransport sees cancellation), `startAfterPauseAppends`, `clearKeepsStreamingAndResetsDropped`, `droppedCountAccumulates` (queue capacity 10, fake yields 25 before one drain → `droppedCount == 15`), `childDeathGoesFailedThenRetry` (fake finishes throwing → `.failed`; `retry()` → `.streaming`, transport call count 2), `budgetEnforcedOnDrain`.
  - Registry: `rowsMergeDiscoveries` (order mac, physical, simulator), `disappearWhileStreamingKeepsRowGreyed`, `reappearAutoResumesOnce` (disappear/reappear, then a duplicate reappear update → transport call count exactly 2), `flappingDoesNotDuplicate` (disappear, reappear, disappear, reappear in one run loop turn → at most one active stream), `pausedStaysPausedOnReturn`, `emptySessionRowRemovedOnDisappear`, `errorThenDisappearBecomesDisconnected`.
- [ ] **Step 2:** Run `--filter BCStreamingTests` → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(streaming): sessions, registry and bounded queue`.

---

### Task 7: App target, window shell, sidebar, empty state, toolbar

**Files:**
- Create: `project.yml`, `App/BetterConsoleApp.swift`, `App/AppEnvironment.swift`, `App/Sidebar/DeviceSidebar.swift`, `App/LogView/LogView.swift`, `App/BetterConsole.entitlements`
- Generate: `BetterConsole.xcodeproj` via `xcodegen generate`

**Interfaces:**
- Consumes: `SessionRegistry`, `StreamSession`, `MemoryBudget`, `ProcessLogTransport`, `LocalMacDiscovery`, `SimulatorDiscovery`.
- Produces: `@MainActor final class AppEnvironment { let budget: MemoryBudget; let registry: SessionRegistry; static func live() -> AppEnvironment }` — the only place transports/discoveries are registered (Task 10 adds two lines here). `LogView(session: StreamSession)` hosts the table from Task 8.

`project.yml` decisions: one target `BetterConsole` (application, macOS 26.0), sources `App/`, local package dependency `Packages/BetterConsoleKit` linking `BCModel BCStore BCTransport BCStreaming` (and `BCMobileDevice` in Task 10), `ENABLE_HARDENED_RUNTIME: YES`, `CODE_SIGN_ENTITLEMENTS: App/BetterConsole.entitlements` (`com.apple.security.app-sandbox` = false), `SWIFT_VERSION: 6.0`, `PRODUCT_BUNDLE_IDENTIFIER` placeholder `app.betterconsole.BetterConsole` (user sets final id + team).

- [ ] **Step 1:** Write `project.yml`, run `xcodegen generate` → `BetterConsole.xcodeproj` created.
- [ ] **Step 2:** Implement the shell: `NavigationSplitView`; sidebar sections "This Mac", "Devices", "Simulators" (section hidden when empty) with SF Symbols `laptopcomputer` / `iphone` / `ipad` (by model prefix) / `apps.iphone`; unavailable rows rendered with `.secondary` foreground but still selectable. Detail: `LogView` with toolbar buttons Start/Pause (toggle), Now, Clear, title showing device name + "N messages" + "N dropped" (only when > 0); empty state with exact copy from Global Constraints when `store.count == 0 && state != .streaming`; banner for `.failed` (message + Retry) and `.disconnected` ("Device disconnected — will resume when it reconnects" if `wasStreaming`, else "Device disconnected"). Placeholder table area until Task 8.
- [ ] **Step 3:** `xcodebuild -project BetterConsole.xcodeproj -scheme BetterConsole -destination 'platform=macOS' build` → `** BUILD SUCCEEDED **`.
- [ ] **Step 4:** Run the app; verify sidebar shows this Mac; boot a simulator (`xcrun simctl boot "iPhone 16 Pro"`) → appears within ~3 s; shut it down → disappears (no logs collected).
- [ ] **Step 5:** Commit `feat(app): window shell, sidebar and toolbar` (include generated project).

---

### Task 8: Log table, detail pane, auto-scroll, quit cleanup

**Files:**
- Create: `App/LogView/{LogTableView,LogColumns,LogDetailView}.swift`
- Modify: `App/LogView/LogView.swift`, `App/BetterConsoleApp.swift`

**Interfaces:**
- Consumes: `StreamSession.store`, `StreamSession.revision`, `ChildProcessRegistry.shared.terminateAll()`.
- Produces: `struct LogColumn: Identifiable { let id: String; let title: String; let width: CGFloat; let value: (LogEntry) -> String }` and `static let defaultColumns: [LogColumn]` = Time(150), Type(40, rendered as dot), Process(140), Subsystem(200), Category(140), Message(flexible). The table is built by iterating this list (spec: no hard-coded cells; enables column customisation later).

Decisions: view-based `NSTableView`, `usesAutomaticRowHeights = false`, fixed row height 18, monospaced-digit system font 11 pt; cells via `makeView(withIdentifier:)` reuse; data source reads `store[row]` directly. On `revision` change: if the scroll view was at the bottom before the update, `noteNumberOfRowsChanged()` then `scrollRowToVisible(count-1)`; if not at bottom, `reloadData()` preserving the visible first row adjusted for evicted entries (follow mode off). **Now** re-enables follow mode and scrolls to bottom. Time formatter: `Date.FormatStyle` won't do µs → format `HH:mm:ss` via cached formatter + 6-digit µs from `date.timeIntervalSince1970` fractional part. Message column shows the first line only. Detail pane (`VSplitView`, default 30 % height): full message (selectable, monospaced), then a two-column list of every non-nil field and each `extra` key. `applicationWillTerminate` → `ChildProcessRegistry.shared.terminateAll()`.

- [ ] **Step 1:** Implement table + columns + detail + quit hook.
- [ ] **Step 2:** Build (command from Task 7) → `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Manual check:** stream this Mac → rows appear and follow; scroll up → stops following while count rises; Now → back to bottom and following; select a row → detail shows all fields; Pause → count stops; Start → continues; Clear → empty state not shown while streaming, table empties.
- [ ] **Step 4: Quit check:** while streaming Mac + a simulator, ⌘Q, then `pgrep -fl "log stream"` → no output.
- [ ] **Step 5:** Commit `feat(app): log table, detail pane, auto-scroll`.

---

### Task 9: Settings — memory budget

**Files:**
- Create: `App/Settings/SettingsView.swift`
- Modify: `App/BetterConsoleApp.swift` (add `Settings { SettingsView() }`), `App/AppEnvironment.swift`

Decisions: `@AppStorage("maxLogMemoryGB")` Double, default 4, stepper/slider 0.5…64 GB in 0.5 steps, label "Maximum memory for logs"; changes write `budget.limitBytes = Int(gb * 1_073_741_824)` immediately (spec: lowering takes effect immediately); value applied at launch in `AppEnvironment.live()`.

- [ ] **Step 1:** Implement. **Step 2:** Build → success.
- [ ] **Step 3: Manual check:** stream Mac until > 300 MB in Activity Monitor; set 0.5 GB → memory drops and oldest rows disappear from the top while streaming continues; relaunch → setting persisted.
- [ ] **Step 4:** Commit `feat(app): memory budget setting`.

---

### Task 10: Physical devices via MobileDevice (only if Task 0 passed)

**Files:**
- Create: `Sources/BCMobileDevice/{MobileDeviceAPI,MobileDeviceDiscovery,OSTraceDecoder,MobileDeviceLogTransport}.swift`
- Test: `Tests/BCMobileDeviceTests/OSTraceDecoderTests.swift` (uses Task 0 fixtures)
- Modify: `App/AppEnvironment.swift` (register discovery + transport), `project.yml` (link `BCMobileDevice`), delete `Spikes/`

**Interfaces:**
- Consumes: `LogTransport`, `DeviceDiscovery`, `LogEntry`, `LogDevice`, `LineSplitter`-style framing knowledge from `Spikes/OSTraceSpike/RESULT.md`.
- Produces:
  - `MobileDeviceAPI` (internal): `static func load() -> MobileDeviceAPI?` — `dlopen` + `dlsym` of the functions used in Task 0; nil if unavailable (then discovery emits `[]` forever and transport `supports` returns false).
  - `public struct MobileDeviceDiscovery: DeviceDiscovery` — notification-driven; `LogDevice(id: UDID, name: DeviceName, kind: .physical, model: ProductType mapped to marketing name when known else raw, osVersion: "iOS " + ProductVersion)`.
  - `public struct OSTraceDecoder { public init(); public mutating func feed(_ bytes: Data) -> [LogEntry] }` — handles frames split across reads; maps fields into `LogEntry` (unmapped wire fields → `extra`).
  - `public struct MobileDeviceLogTransport: LogTransport` — `supports` only `.physical`; same batching rule as Task 4 (1,000 / 50 ms); cancellation invalidates the service connection; connection loss → throws.

- [ ] **Step 1: Failing tests:** `decodesFixtureFrames` (pid, level, process, subsystem, category, message match Task 0 printout for each fixture), `handlesFrameSplitAcrossFeeds` (feed fixture byte by byte → same entries), `unknownLevelMapsToDefault`, `truncatedFrameWaitsForMore`.
- [ ] **Step 2:** Run `--filter OSTraceDecoderTests` → FAIL. **Step 3:** Implement decoder, then API/discovery/transport. **Step 4:** Run → PASS.
- [ ] **Step 5: Manual check (USB, iOS 26+):** plug in PhoneVac → appears under Devices; Start → logs flow; unplug → row greyed, banner "will resume"; replug → streaming resumes automatically into the same table. Record Wi-Fi result.
- [ ] **Step 6:** `rm -rf Spikes`; regenerate project; build; commit `feat(device): physical iOS log streaming via MobileDevice`.

---

### Task 11: Throughput, signing and release check

**Files:**
- Create: `scripts/flood.sh` (spawns 4 background loops of `logger -t BCFlood` — or a tiny Swift CLI using `os_log` at debug level — to push ≥ 20k msg/s), `docs/RELEASE.md` (build, sign, notarize, DMG steps)

- [ ] **Step 1:** Run the app streaming this Mac, start `scripts/flood.sh`, record in Instruments (Time Profiler + Hangs) for 60 s. Pass = no hang > 16 ms on main, dropped counter either 0 or visibly counting, UI responsive. If it fails: profile decoder first (swap to `JSONDecoder` or a hand-rolled scanner only if it's the hotspot), then drain cost.
- [ ] **Step 2:** Archive with Developer ID + hardened runtime, `xcrun notarytool submit --wait`, staple, build DMG (`hdiutil create`). Launch the notarized copy from `/Applications`: Mac, simulator and USB device streaming all still work (confirms no entitlement or library-validation surprises).
- [ ] **Step 3:** Write `docs/RELEASE.md` with the exact commands used. Commit `chore: throughput check and release procedure`.

---

## Not covered by automated tests (stated, not skipped)

- Real `log` / `simctl` / MobileDevice behaviour beyond captured fixtures — covered by the manual checks in Tasks 7–11.
- UI behaviour (auto-scroll, empty state, banners) — manual checks in Tasks 7–9; no UI test target in the MVP.
- Wi-Fi device streaming and iOS < 26 — best effort, result recorded in Task 0 / Task 10.
- Paired-but-unreachable phones (spec §6.3) are shown only if MobileDevice reports them; devices with a prior session always show greyed via `SessionRegistry`.
