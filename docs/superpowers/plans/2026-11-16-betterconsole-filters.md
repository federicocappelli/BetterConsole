# BetterConsole Filters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A filter bar above the log list (saved-filter dropdown, bubble field, Save, "…" menu), a private saved-filter library with JSON import/export, per-device filters, a Console-style right-click Hide/Show menu, and filtering that never stalls the window.

**Architecture:** A new pure package module `BCFilter` holds the filter model, evaluation, the export file format, bubbles ↔ tree mapping, suggestions, the saved-filter library and per-device filter state. `BCStreaming` gains per-session filtering: entries are checked off the main thread before the drain, a match index maps table rows to store positions, and a filter change rescans the store newest-first in the background. The app adds the filter bar, rewires the table to the session's rows, and adds the right-click menu.

**Tech Stack:** Swift 6 (complete strict concurrency), SwiftUI + AppKit (`NSTableView`), Swift Testing, XcodeGen 2.46, macOS 26.

**Spec:** `docs/superpowers/specs/2026-11-16-betterconsole-filters-design.md` (builds on `docs/superpowers/specs/2026-11-13-betterconsole-mvp-design.md`). Section numbers below (§) refer to the filters spec.

## Global Constraints

- macOS 26.0 deployment target; Swift 6 language mode; `SWIFT_STRICT_CONCURRENCY: complete` in the app.
- No third-party dependencies.
- Signing stays ad-hoc (`CODE_SIGN_IDENTITY "-"`, empty `DEVELOPMENT_TEAM`). Never use any certificate or team from this Mac's keychain. Keep team IDs and certificate names out of commits.
- `project.yml` is the source of truth; after changing it run `xcodegen generate` and commit the regenerated `BetterConsole.xcodeproj` in the same commit.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Main thread: whole drain (store append, index append, table update) under 16 ms per frame at ~27,000 messages/s; each main-thread step of a rescan under 4 ms (§8.2, §8.3).
- Rescan of 800,000 entries with a typical filter (five bubbles, contains/is) within 1 second on the development Mac, Release build (§8.3).
- Live checking at ~27,000 messages/s under 10 % of one core for a typical filter (§8.4).
- Export format: `"format": "betterconsole.filter"`, `"version": 1`; field ids `process`, `pid`, `library`, `thread`, `subsystem`, `category`, `type`, `activity`, `message`; match ids `contains`, `is`, `startsWith`, `regex`; import limits 1 MB and nesting depth 32 (§5.3).
- Text matching ignores case; a missing value never matches a condition (§5.1).
- Suggestion values capped at 5,000 per field (§8.5).
- The library is private to the app (Application Support, never shown, read once at launch, atomic writes); filters enter and leave only via Import/Export (§9).
- User-visible strings exactly as in the spec: "New Filter", "Untitled", "(Edited)", "Filtering…", "Edit" (disabled, tooltip "Coming soon"), "Errors and Faults", "Hide …"/"Show …" items as `Hide Process 'Console'`, "Copy", "Copy Message", subtitle "1,204 of 45,348 messages".

## Review Focus

1. **A filter that matches nothing while messages exist** — the list must say so ("No Matching Messages"), not show the MVP's "No Messages / Start streaming" overlay or a blank pane. Test in Task 8.
2. **Values with regex or quote characters** (`com.apple.(x)`, `Plugin-Apple Internal`, `it's`) used by Hide/Show or typed with "is"/"contains" — matching must be literal. Test in Task 1.
3. **Non-ASCII text** (`Éclair` vs `éclair`, `STRASSE` vs `straße` is not required, but accented letters are) — "ignores case" must hold for accented letters. Test in Task 1.
4. **Whitespace-only or padded typing** (`"   "`, `"  cfnet  "`) — no empty bubble is created; values are trimmed. Test in Task 3.
5. **A pathological regex** (`(a+)+$` against a long message) — the window stays responsive and a newer filter change still takes effect promptly; the rescan checks for cancellation between entries. Test in Task 6.

---

## File Structure

```
Packages/BetterConsoleKit/
  Package.swift                                  modify: add BCFilter (+tests); BCStreaming depends on BCFilter
  Sources/BCFilter/
    FilterExpression.swift                       FilterField, MatchKind, FilterCondition, FilterExpression (+Codable)
    CompiledFilter.swift                         evaluation; condition value problems
    FilterFile.swift                             SavedFilter, export encode/decode, FilterImportError
    Bubbles.swift                                Bubble, BubbleCodec, BubbleLayout, BubbleEditing
    QuickFilterItems.swift                       right-click Hide/Show items from a LogEntry
    SeenValues.swift                             distinct values per field (capped)
    FilterSuggestions.swift                      suggestion list for typed text
    FilterLibrary.swift                          FilterLibrary, FilterLibraryStorage, FileFilterLibraryStorage
    FilterWorkspace.swift                        DeviceFilterState, DeviceFilterPersistence, FilterWorkspace
  Sources/BCStreaming/
    BoundedBatchQueue.swift                      modify: tagged batches
    FilterSlot.swift                             compiled filter + generation shared with the consumer
    MatchIndex.swift                             absolute positions of matches
    LogRows.swift                                the table's view of a session (direct or filtered)
    StreamSession.swift                          modify: filter, rows, rescan, seen values
    SessionRegistry.swift                        modify: onSessionCreated hook
  Tests/BCFilterTests/…                          one file per source file
  Tests/BCStreamingTests/…                       MatchIndexTests, StreamSessionFilterTests, FilterPerformanceTests
App/
  AppEnvironment.swift                           modify: library, workspace, wiring, probe filter
  Filter/FilterBar.swift                         dropdown · bubble field · Save · "…"
  Filter/BubbleField.swift                       wrapping bubbles, connectors, text input, suggestions
  Filter/BubbleView.swift                        one bubble and its menu
  Filter/FilterDialogs.swift                     name sheet, save/discard prompt, delete confirm, import report
  LogView/LogView.swift                          modify: filter bar, subtitle, empty states
  LogView/LogTableView.swift                     modify: rows mapping, anchoring, menu, copy
  LogView/RowCopy.swift                          tab-separated line for Copy
Tests/BetterConsoleTests/RowCopyTests.swift
project.yml                                      modify: BCFilter product; RowCopy.swift into the test bundle
```

---

### Task 1: BCFilter model and evaluation

**Files:**
- Modify: `Packages/BetterConsoleKit/Package.swift` (add `.library(name: "BCFilter")`, `.target(name: "BCFilter", dependencies: ["BCModel"])`, `.testTarget(name: "BCFilterTests", dependencies: ["BCFilter", "BCModel"])`)
- Create: `Sources/BCFilter/FilterExpression.swift`, `Sources/BCFilter/CompiledFilter.swift`
- Test: `Tests/BCFilterTests/CompiledFilterTests.swift`, `Tests/BCFilterTests/FilterExpressionCodingTests.swift`

**Interfaces:**
- Consumes: `LogEntry`, `LogLevel` (BCModel).
- Produces:
  - `public enum FilterField: String, Codable, Sendable, CaseIterable { case process, pid, library, thread, subsystem, category, type, activity, message }` with `public var title: String` ("Process", "PID", "Library", "Thread ID", "Subsystem", "Category", "Type", "Activity ID", "Message") and `public var allowedMatches: [MatchKind]` (§5.1 table: pid/thread/activity/type → `[.is]`, others all four).
  - `public enum MatchKind: String, Codable, Sendable, CaseIterable { case contains, `is`, startsWith, regex }` with `title` ("contains", "is", "starts with", "matches regex").
  - `public struct FilterCondition: Hashable, Codable, Sendable { public var field: FilterField; public var match: MatchKind; public var value: String; public var isEnabled: Bool = true }` with `public var valueProblem: String?` — non-nil for an invalid regex ("Invalid regular expression: …"), a PID/Activity ID that is not a decimal integer, a Thread ID that is neither `0x…` hex nor decimal, or a Type value outside `default, info, debug, error, fault` (case-insensitive).
  - `public indirect enum FilterExpression: Hashable, Sendable, Codable { case condition(FilterCondition), all([FilterExpression]), any([FilterExpression]), not(FilterExpression) }`. JSON shape is single-key objects exactly as §5.3: `{"condition":{…}}`, `{"all":[…]}`, `{"any":[…]}`, `{"not":{…}}`; `isEnabled` is omitted when true.
  - `public struct CompiledFilter: Sendable { public init(_ expression: FilterExpression?); public var matchesEverything: Bool; public func matches(_ entry: LogEntry) -> Bool }`.

- [ ] **Step 1: Write failing tests** in `CompiledFilterTests.swift` (Swift Testing; build entries with a local `makeEntry(process:pid:sender:thread:subsystem:category:level:activity:message:)` helper):
  - `everyFieldAndMatch`: for each field × allowed match a matching and a non-matching entry, e.g. `process contains "brigh"` matches `corebrightnessd`; `library is "CoreFoundation"` matches `senderImagePath "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"`; `thread is "0xa6fc7"` and `thread is "683975"` both match `threadID 0xa6fc7`; `type is "Debug"` matches `.debug`; `message startsWith "hello"` matches `"Hello world"`; `subsystem regex "^com\\.apple\\.(cfnet|net)"` matches `com.apple.network`.
  - `ignoresCaseIncludingAccents`: `message contains "éclair"` matches `"ÉCLAIR ready"` (Review Focus 3).
  - `literalSpecialCharacters`: `subsystem is "com.apple.(x)"` matches exactly that and not `com.apple.x`; `category contains "Apple Internal"` matches `"Plugin-Apple Internal"`; `message contains "it's"` matches `"it's done"` (Review Focus 2).
  - `missingValueNeverMatches`: `subsystem contains "a"` false for nil subsystem; `.not(that)` true; `activity is "0"` false when `activityID == nil`.
  - `invalidConditionsAreDropped`: `all([process is "x", regex "(" ])` behaves as `process is "x"`; `any` whose only child is invalid → no constraint; `.not(invalid)` → no constraint; an expression of only invalid conditions → `matchesEverything == true`.
  - `disabledConditionDropped`: `isEnabled: false` behaves like an invalid condition.
  - `nilAndEmptyMatchEverything`: `CompiledFilter(nil).matchesEverything`, `CompiledFilter(.all([])).matchesEverything`.
  - `valueProblems`: `regex "("` → non-nil; `pid is "12a"` → non-nil; `thread is "0xZZ"` → non-nil; `type is "warning"` → non-nil; `type is "FAULT"` → nil.
- [ ] **Step 2: Write failing coding tests** in `FilterExpressionCodingTests.swift`: `roundTrip` (nested tree encodes and decodes equal); `shapeMatchesSpec` (encoding `.not(.condition(type is debug))` with sorted keys gives `{"not":{"condition":{"field":"type","match":"is","value":"debug"}}}`); `isEnabledOmittedWhenTrue`; `unknownFieldFailsDecoding` (`"field":"zone"` throws).
- [ ] **Step 3: Run to see them fail**: `swift test --package-path Packages/BetterConsoleKit --filter BCFilterTests` → compile errors (types not defined).
- [ ] **Step 4: Implement** the types above. `CompiledFilter` compiles once into a private node tree: text compared with `range(of:options: .caseInsensitive)` (case-insensitive, accent-sensitive; `is` uses `compare(_:options: .caseInsensitive) == .orderedSame`, `startsWith` adds `.anchored`), needles prepared once, regexes as `NSRegularExpression(pattern:options: .caseInsensitive)`, numeric values parsed once, Type compared on `LogLevel`. Library value = last path component of `senderImagePath` (computed per check without `URL`; scan for the last `/`).
- [ ] **Step 5: Run**: same command → all pass.
- [ ] **Step 6: Commit** `feat(filter): BCFilter model and evaluation`.

### Task 2: Export file format and import validation

**Files:**
- Create: `Sources/BCFilter/FilterFile.swift`
- Test: `Tests/BCFilterTests/FilterFileTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
  - `public struct SavedFilter: Identifiable, Hashable, Codable, Sendable { public var id: UUID; public var name: String; public var expression: FilterExpression? }` (`nil` expression = empty filter).
  - `public enum FilterFile { public static let format = "betterconsole.filter"; public static let version = 1; public static let maxBytes = 1_048_576; public static let maxDepth = 32; public static func encode(_ filter: SavedFilter) throws -> Data; public static func decode(_ data: Data) throws(FilterImportError) -> SavedFilter }` — `encode` writes the §5.3 object (pretty-printed, sorted keys; a nil expression is written as `{"all":[]}` so every file has one, and decodes back to nil).
  - `public enum FilterImportError: Error, Equatable, CustomStringConvertible { case tooLarge, notJSON, tooDeep, wrongFormat, newerVersion(Int), missingName, missingExpression, unknownField(String), unknownMatch(String), disallowedMatch(field: String, match: String), badTypeValue(String), disabledCondition }` — descriptions are plain sentences, e.g. `"The file is larger than 1 MB."`, `"The file was made by a newer version of BetterConsole (format version 2)."`, `"Unknown field “zone”."`, `"“regex” can't be used with PID."`.

- [ ] **Step 1: Write failing tests**: `exportImportRoundTrip`; `importRejects` — one `#expect(throws:)` per case in §5.3 producing exactly: >1 MB → `.tooLarge`; `"nope"` → `.notJSON`; 33 nested `not` → `.tooDeep`; `"format":"other"` → `.wrongFormat`; `"version":2` → `.newerVersion(2)`; missing/blank `name` → `.missingName`; no `expression` → `.missingExpression`; `"field":"zone"` → `.unknownField("zone")`; `"match":"near"` → `.unknownMatch("near")`; pid+regex → `.disallowedMatch(field:"pid", match:"regex")`; type+contains → `.disallowedMatch(field:"type", match:"contains")`; `type is "warning"` → `.badTypeValue("warning")`; `"isEnabled":false` → `.disabledCondition`; `importAcceptsValueProblems` — `message regex "("` and `pid is "12a"` import fine; `unknownExtraKeysIgnored`; `idAndNameRead` (id and name from file; a missing or malformed `id` gets a fresh UUID).
- [ ] **Step 2: Run to see them fail**: `swift test --package-path Packages/BetterConsoleKit --filter FilterFileTests`.
- [ ] **Step 3: Implement** `FilterFile`: check size first, then parse with `JSONSerialization` to measure depth and read `format`/`version`/`name`, then walk the expression dictionary yourself to produce the specific errors (do not rely on Codable error messages).
- [ ] **Step 4: Run** → pass.
- [ ] **Step 5: Commit** `feat(filter): export format and import validation`.

### Task 3: Bubbles, suggestions, seen values, Hide/Show items

**Files:**
- Create: `Sources/BCFilter/Bubbles.swift`, `SeenValues.swift`, `FilterSuggestions.swift`, `QuickFilterItems.swift`
- Test: `Tests/BCFilterTests/BubblesTests.swift`, `FilterSuggestionsTests.swift`, `QuickFilterItemsTests.swift`

**Interfaces:**
- Consumes: Task 1 types, `LogEntry`.
- Produces:
  - `public struct Bubble: Identifiable, Hashable, Sendable { public let id: UUID; public var content: Content; public enum Content: Hashable, Sendable { case condition(FilterCondition, include: Bool), advanced(FilterExpression) } }`
  - `public enum BubbleCodec { public static func bubbles(from expression: FilterExpression?) -> [Bubble]; public static func expression(from bubbles: [Bubble]) -> FilterExpression? }` — reading rules and writing order exactly §5.2; empty list ↔ `nil`.
  - `public enum Connector: Sendable { case and, or }`; `public enum BubbleLayout { public static func ordered(_ bubbles: [Bubble]) -> [Bubble]; public static func connector(between left: Bubble, and right: Bubble) -> Connector }` — order: advanced bubbles (in order), include bubbles grouped by field in first-appearance order, exclude bubbles (in order); `.or` only for two includes on the same field.
  - `public enum BubbleEditing { public static func adding(_ condition: FilterCondition, include: Bool, to bubbles: [Bubble]) -> [Bubble] }` — identical (same condition and include) → unchanged; same condition opposite include → replaced in place; else appended.
  - `public struct SeenValues: Sendable { public static let capPerField = 5_000; public init(); public mutating func insert(_ entry: LogEntry); public func values(for field: FilterField) -> [String] }` — tracks process, subsystem, category, library; past the cap new values are ignored.
  - `public struct FilterSuggestion: Hashable, Sendable { public var condition: FilterCondition; public var title: String }`; `public enum FilterSuggestions { public static let valuesPerField = 3; public static func make(for text: String, seen: SeenValues) -> [FilterSuggestion] }` — trims whitespace; empty → `[]`; first `message contains <text>` titled `Message contains "<text>"`; then for Process, Subsystem, Category, Library up to 3 seen values containing the text (case-insensitive; shortest first, then alphabetical) as `is` titled `Process is "cfnetworkagent"`; then `Subsystem contains …`, `Category contains …`, `Process contains …`.
  - `public struct QuickFilterItem: Hashable, Sendable { public var condition: FilterCondition; public var menuValue: String }`; `public enum QuickFilterItems { public static let maxMenuValueLength = 60; public static func items(for entry: LogEntry) -> [QuickFilterItem] }` — order Process, PID, Library, Thread ID, Subsystem, Category, Type, Activity ID; omit missing values; Thread as `0x` + lowercase hex; Type as lower-case raw (`debug`); Activity ID 0 included; condition match `is` with the full value; `menuValue` middle-truncated with `…` when longer than 60 characters.

- [ ] **Step 1: Write failing tests**:
  - `BubblesTests`: `roundTripBarShape` (bubbles → tree → bubbles keeps contents and display order); `writesSpecOrder` (`[exclude type debug, include process A, advanced X, include process B]` writes `all([X, any([A, B]), not(type debug)])`); `lenientReading` — bare condition → include; one-item `all` flattened; `not(condition)` → exclude; `any` mixing fields → one advanced; `not(any(…))` → one advanced; non-`all` root wrapped; `advancedSurvivesSaveReload` (advanced + plain bubbles → tree → bubbles gives the same advanced bubble and the same plain bubbles); `connectorWords` (same-field includes → `.or`, different fields → `.and`, include vs exclude same field → `.and`, advanced next to anything → `.and`); `addingRules` (duplicate no-op, opposite replaces at the same index, new appends).
  - `FilterSuggestionsTests`: `whitespaceOnlyGivesNothing` (`"   "` → `[]`, Review Focus 4); `trimsTypedText` (`"  cfnet  "` → first title `Message contains "cfnet"`); `orderAndCaps` (with 5 matching seen processes only 3 offered, shortest first); `seenValuesCap` (5,001 distinct processes → 5,000 kept).
  - `QuickFilterItemsTests`: `macRow` (all eight items, values `Console`, `20368`, `CoreFoundation`, `0xa6fc7`, `com.apple.defaults`, `User Defaults`, `debug`, `0`); `iPhoneRowOmitsActivity` (`activityID == nil` → 7 items); `omitsMissingSubsystem`; `longValueTruncatedInMenuOnly` (100-char subsystem → `menuValue.count == 60`, contains `…`, `condition.value` full).
- [ ] **Step 2: Run to see them fail**: `swift test --package-path Packages/BetterConsoleKit --filter BCFilterTests`.
- [ ] **Step 3: Implement** the four files.
- [ ] **Step 4: Run** → pass.
- [ ] **Step 5: Commit** `feat(filter): bubbles, suggestions and Hide/Show items`.

### Task 4: Saved-filter library and per-device state

**Files:**
- Create: `Sources/BCFilter/FilterLibrary.swift`, `Sources/BCFilter/FilterWorkspace.swift`
- Test: `Tests/BCFilterTests/FilterLibraryTests.swift`, `Tests/BCFilterTests/FilterWorkspaceTests.swift`

**Interfaces:**
- Consumes: `SavedFilter`, `FilterFile`, `FilterImportError`, `FilterExpression`.
- Produces:
  - `public protocol FilterLibraryStorage: Sendable { func load() throws -> Data?; func save(_ data: Data) throws; func moveAside() throws }`; `public struct FileFilterLibraryStorage: FilterLibraryStorage { public init(directory: URL) }` — file `FilterLibrary.json` in `directory`, written with `.atomic`; `moveAside` renames it to `FilterLibrary-damaged-<yyyyMMdd-HHmmss>.json`.
  - Library file content: `{"version":1,"starterCreated":true,"filters":[<FilterFile objects without "format">…]}` (builder may add fields; it is private).
  - `@MainActor @Observable public final class FilterLibrary`:
    - `public init(storage: any FilterLibraryStorage)` — loads once; if `load()` returns nil (first launch) creates "Errors and Faults" = `.any([type is error, type is fault])` and sets `starterCreated`; if the data cannot be read, calls `moveAside()`, starts empty with `starterCreated = true`, and sets `loadProblem` to `"Your saved filters could not be read. They were set aside and BetterConsole started with an empty filter list."`.
    - `public private(set) var filters: [SavedFilter]` sorted by `localizedStandardCompare` of name; `public private(set) var loadProblem: String?`; `public func acknowledgeLoadProblem()`.
    - `public func filter(id: UUID) -> SavedFilter?`
    - `@discardableResult public func add(name: String, expression: FilterExpression?) -> SavedFilter` (name made unique: `"X"`, `"X 2"`, `"X 3"`…)
    - `public func update(id: UUID, expression: FilterExpression?)`, `public func rename(id: UUID, to name: String)` (unique, ignoring itself), `public func delete(id: UUID)`
    - `public func importFiles(_ urls: [URL]) -> ImportReport` with `public struct ImportReport: Sendable { public var imported: [SavedFilter]; public var rejected: [(fileName: String, reason: String)] }` — every imported filter gets a new UUID; names made unique.
    - `public func export(id: UUID, to url: URL) throws`
    - every mutation saves through `storage`.
  - `public struct DeviceFilterState: Codable, Hashable, Sendable { public var basedOn: UUID?; public var expression: FilterExpression?; public var isEdited: Bool; public static let empty }`
  - `public protocol DeviceFilterPersistence { func load() -> [String: DeviceFilterState]; func save(_ states: [String: DeviceFilterState]) }`; `public struct UserDefaultsDeviceFilterPersistence: DeviceFilterPersistence { public init(defaults: UserDefaults = .standard, key: String = "deviceFilters") }`.
  - `@MainActor @Observable public final class FilterWorkspace`:
    - `public init(library: FilterLibrary, persistence: any DeviceFilterPersistence)` — restored states whose `basedOn` is missing from the library become `basedOn = nil, isEdited = expression != nil`; states based on a filter and not edited take the filter's current expression.
    - `public var onExpressionChange: (@MainActor (_ deviceID: String, _ expression: FilterExpression?) -> Void)?` — called whenever a device's expression changes for any reason.
    - `public func state(for deviceID: String) -> DeviceFilterState`
    - `public func displayName(for deviceID: String) -> String` ("Untitled" or the saved name)
    - `public func setExpression(_ expression: FilterExpression?, for deviceID: String)` — sets `isEdited = true`.
    - `public func select(_ filterID: UUID?, for deviceID: String)` — nil = "New Filter" (empty, Untitled, not edited); clears edits (prompting is the UI's job).
    - `public func save(for deviceID: String)` — precondition `basedOn != nil`; writes to the library; every other device with the same `basedOn` and `!isEdited` takes the new expression.
    - `@discardableResult public func saveAs(name: String, for deviceID: String) -> SavedFilter` — only this device switches.
    - `public func discard(for deviceID: String)` — back to the saved expression (or empty for Untitled), not edited.
    - `public func rename(_ filterID: UUID, to name: String)`
    - `@discardableResult public func duplicate(for deviceID: String) -> SavedFilter` — library copy named `"<name> copy"` holding the **saved** expression; the device switches to it and keeps its current expression and `isEdited` flag.
    - `public func delete(_ filterID: UUID)` — devices based on it become `basedOn = nil, isEdited = true` (keep bubbles).
    - persists after every change.

- [ ] **Step 1: Write failing library tests** with an in-memory `FakeStorage` (records saves, can be primed with data or made to throw on load): `firstLaunchCreatesStarterOnce` (starter present; delete it; new library from the same storage has no starter); `damagedLibraryMovedAside` (garbage data → `moveAside` called, `filters` empty, `loadProblem` set, no starter); `uniqueNames` (`add` "A" twice → "A", "A 2"); `renameUnique`; `importReport` (two files, one valid one `.notJSON` → 1 imported with a new UUID, 1 rejected with the error's description; importing the same valid file twice → names "X", "X 2"); `exportedFileIsNotLinked` (export, edit the file on disk, library unchanged); `fileStorageAtomicAndMoveAside` using a temporary directory.
- [ ] **Step 2: Write failing workspace tests**: `saveAsSwitchesOnlyThisDevice`; `savePropagatesToUneditedOnly` (Mac and phone on filter F; phone edited; Mac saves new expression → sim on F unedited gets it, phone keeps its edits and stays edited; `onExpressionChange` called for sim only besides Mac); `deleteMakesDevicesUntitledEdited`; `duplicateMovesDeviceToCopyWithEdits`; `discardRestoresSaved`; `restoreAcrossRelaunch` (new workspace from the same persistence + library restores each device; a device based on a deleted filter becomes Untitled edited); `selectClearsEdits`.
- [ ] **Step 3: Run to see them fail**: `swift test --package-path Packages/BetterConsoleKit --filter "FilterLibraryTests|FilterWorkspaceTests"`.
- [ ] **Step 4: Implement** both files.
- [ ] **Step 5: Run** → pass.
- [ ] **Step 6: Commit** `feat(filter): saved-filter library and per-device state`.

### Task 5: Match index and session rows

**Files:**
- Create: `Sources/BCStreaming/MatchIndex.swift`, `Sources/BCStreaming/LogRows.swift`
- Modify: `Packages/BetterConsoleKit/Package.swift` (`BCStreaming` and `BCStreamingTests` depend on `BCFilter`)
- Test: `Tests/BCStreamingTests/MatchIndexTests.swift`

**Interfaces:**
- Consumes: `LogStore` (`count`, `removedCount`, subscript).
- Produces:
  - `struct MatchIndex` (internal; absolute positions, ascending): `init()`, `var count: Int`, `subscript(row: Int) -> Int`, `mutating func append(_ position: Int)` (precondition ascending), `mutating func prepend(_ positionsNewestFirst: [Int])` (precondition all below the current first), `mutating func dropBelow(_ position: Int) -> Int` (returns rows removed from the front), `mutating func removeAll()`, `func row(forPosition: Int) -> Int?`, `func row(atOrBefore position: Int) -> Int?` (binary search). Store it as two arrays — `older` filled newest-first by the rescan (so eviction is `removeLast`) and `newer` filled by live appends — or any equivalent with these complexities: append/prepend amortised O(1) per item, drop O(k), lookups O(log n).
  - `@MainActor public final class LogRows` — the table's view of one session:
    - `public var count: Int`, `public subscript(row: Int) -> LogEntry`, `public func position(ofRow row: Int) -> Int`, `public func row(forPosition: Int) -> Int?`, `public func row(atOrBefore position: Int) -> Int?`
    - `public private(set) var insertedAtFront: Int` and `public private(set) var removedFromFront: Int` — monotonic counters since the last reset.
    - `public private(set) var resetCount: Int` — bumped whenever the row set is replaced (filter change, `clear()`).
    - `public var isFiltered: Bool` — false: rows map straight to the store (position = `store.removedCount + row`; `removedFromFront` follows the store's `removedCount`).
- [ ] **Step 1: Write failing tests** `MatchIndexTests`: `appendAndLookup`; `prependNewestFirst` (prepend `[9, 7, 4]` before `[12]` → rows `[4, 7, 9, 12]`); `dropBelow` (returns count removed, works across both halves); `rowAtOrBefore` (exact, between, before first → nil); `largeIndexPerformance` (1,000,000 appends + 1,000 `dropBelow` under 200 ms in debug — loose sanity bound).
- [ ] **Step 2: Run to see them fail**: `swift test --package-path Packages/BetterConsoleKit --filter MatchIndexTests`.
- [ ] **Step 3: Implement** `MatchIndex` and `LogRows` (LogRows is exercised in Task 6's tests; give it an internal init taking the store).
- [ ] **Step 4: Run** → pass.
- [ ] **Step 5: Commit** `feat(streaming): match index and session rows`.

### Task 6: Session filtering (live path and rescan)

**Files:**
- Create: `Sources/BCStreaming/FilterSlot.swift`
- Modify: `Sources/BCStreaming/BoundedBatchQueue.swift`, `Sources/BCStreaming/StreamSession.swift`, `Sources/BCStreaming/SessionRegistry.swift`, `Tests/BCStreamingTests/BoundedBatchQueueTests.swift`
- Test: `Tests/BCStreamingTests/StreamSessionFilterTests.swift`

**Interfaces:**
- Consumes: `CompiledFilter`, `FilterExpression`, `SeenValues` (BCFilter); `MatchIndex`, `LogRows` (Task 5).
- Produces:
  - `public struct TaggedBatch: Sendable { public var entries: [LogEntry]; public var matches: [Bool]?; public var generation: UInt64 }` (`matches == nil` → no filter at check time). `BoundedBatchQueue.push(_ batch: TaggedBatch)`; `drain(max:) -> (batches: [TaggedBatch], dropped: Int)` — capacity and drop counting unchanged, counted in entries; a batch cut by `max` or capacity keeps `matches` aligned.
  - `final class FilterSlot: Sendable` — `Mutex<(generation: UInt64, filter: CompiledFilter?)>`; `func current() -> (UInt64, CompiledFilter?)`; `func set(_ filter: CompiledFilter?) -> UInt64` (bumps generation).
  - On `StreamSession`:
    - `public private(set) var filter: FilterExpression?`
    - `public func setFilter(_ expression: FilterExpression?)` — no-op when equal to the current one.
    - `public let rows: LogRows`
    - `public private(set) var isFiltering: Bool` and `public private(set) var filterProgress: Double` (0…1) while a rescan runs.
    - `@ObservationIgnored public private(set) var seenValues: SeenValues` (updated on drain).
  - `SessionRegistry.onSessionCreated: (@MainActor (StreamSession) -> Void)?` — called right after `apply()` creates a session, before it can start.
- Behaviour (spec §8.1–§8.3):
  - Consumer task: for each transport batch, read `slot.current()`, evaluate `matches` when the filter is non-nil and not `matchesEverything`, push a `TaggedBatch`.
  - Drain: append entries to the store as today; for each batch whose generation is current use its `matches`, otherwise re-check on the main actor with the current compiled filter; append matching absolute positions to the index; update `seenValues`; `budget.enforce()` eviction drops index rows below `store.removedCount` (do this where `revision` is bumped by `onEvict`, too).
  - `setFilter`: compile, set the slot, bump `rows.resetCount`. Nil/`matchesEverything` → `rows` in direct mode, no rescan. Otherwise empty index, remember the boundary `B = store.removedCount + store.count`, start a rescan task over `[store.removedCount, B)` **newest to oldest** in chunks: on the main actor copy a chunk of entries (size chosen so the copy stays under 4 ms; start at 10,000), evaluate off the main actor (`Task.detached`), back on the main actor drop positions now below `store.removedCount`, `prepend` the rest, update `filterProgress`. Cancel the running rescan on the next `setFilter` and on `deinit`. Off-main evaluation checks `Task.isCancelled` at least every 1,000 entries.
  - `clear()`: index emptied, `resetCount` bumped; a running rescan finishes with nothing left to add.
- [ ] **Step 1: Update `BoundedBatchQueueTests`** to the tagged API and add `cutBatchKeepsMatchesAligned` (capacity 5, push 8 entries with matches `[t,f,t,f,t,f,t,f]` → drained matches `[t,f,t,f,t]`, dropped 3).
- [ ] **Step 2: Write failing end-to-end tests** in `StreamSessionFilterTests`, driven through a real `StreamSession`, `FakeTransport` and `MemoryBudget` (entries via `makeEntry` with distinct processes; wait for the drain with a short polling helper on `rows.count`/`isFiltering`):
  - `filterOnBeforeStreaming` — set `process is "A"`, stream A/B/A → `rows.count == 2`, both process A.
  - `filterAddedWhileStreaming` — stream 1,000 mixed, set filter, keep streaming 1,000 → after rescan, rows are exactly the matching entries in id order, no duplicates.
  - `filterRemovedBringsEverythingBack` — then `setFilter(nil)` → `rows.count == store.count`, `rows.isFiltered == false`.
  - `filterABA` — A → B → A while streaming → final rows equal a fresh A filter over the same store.
  - `changeDuringRescanLatestWins` — 200,000 entries, set A then B immediately → final rows match B only; `isFiltering` ends false.
  - `evictionDuringRescan` — small budget so eviction runs while rescanning → every row maps to a live entry matching the filter; `rows.count` equals a brute-force count over the store.
  - `clearDuringRescan` — `clear()` mid-rescan → `rows.count == 0`, then new matching entries appear.
  - `staleGenerationRechecked` — push a batch tagged with the old generation after `setFilter` → its entries are judged by the new filter.
  - `disconnectReconnectKeepsFilter` — device disappears and returns → `session.filter` unchanged, new matches indexed.
  - `seenValuesTracked` — streamed processes appear in `seenValues.values(for: .process)`.
  - `pathologicalRegexCancels` (Review Focus 5) — 50,000 entries with 10,000-char messages of `"a"` + `"!"`, set `message regex "(a+)+$"`, then after 100 ms set `process is "A"` → within 2 s `filter` is the second one, `isFiltering == false` and rows match it.
  - `registryHookCalledOnCreate` (in `SessionRegistryTests`) — hook sees each new session once.
- [ ] **Step 3: Run to see them fail**: `swift test --package-path Packages/BetterConsoleKit --filter "BoundedBatchQueueTests|StreamSessionFilterTests|SessionRegistryTests"`.
- [ ] **Step 4: Implement** `FilterSlot`, the queue change, the session changes and the registry hook.
- [ ] **Step 5: Run the whole package suite**: `swift test --package-path Packages/BetterConsoleKit` → all pass (existing `StreamSessionTests` included).
- [ ] **Step 6: Commit** `feat(streaming): per-session filtering with background rescan`.

### Task 7: App wiring

**Files:**
- Modify: `project.yml` (add `BCFilter` product to the app target), `App/AppEnvironment.swift`, `App/BetterConsoleApp.swift`
- Regenerate: `BetterConsole.xcodeproj`

**Interfaces:**
- Consumes: `FilterLibrary`, `FileFilterLibraryStorage`, `FilterWorkspace`, `UserDefaultsDeviceFilterPersistence`, `SessionRegistry.onSessionCreated`, `StreamSession.setFilter`.
- Produces: `AppEnvironment.library: FilterLibrary` and `AppEnvironment.workspace: FilterWorkspace`, available to views through the environment (pass them the same way `registry` reaches views today).
- Wiring: library directory `~/Library/Application Support/BetterConsole/` (create if missing). `registry.onSessionCreated = { workspace.state(for: $0.device.id).expression → session.setFilter }`. `workspace.onExpressionChange = { registry.session(for: id)?.setFilter(expr) }`.
- Probe: when `BETTERCONSOLE_PROBE_FILTER=<path to an exported filter file>` is set alongside `BETTERCONSOLE_PROBE`, decode it with `FilterFile.decode` and apply it to the `local` session before streaming starts (for Task 11).

- [ ] **Step 1: Implement** the wiring.
- [ ] **Step 2: Build**: `xcodegen generate && xcodebuild -project BetterConsole.xcodeproj -scheme BetterConsole -destination 'platform=macOS' build` → `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Verify** the private library appears: launch the built app once, quit, check `~/Library/Application Support/BetterConsole/FilterLibrary.json` exists and contains "Errors and Faults".
- [ ] **Step 4: Commit** `feat(app): wire filter library and per-device filters` (include the regenerated project).

### Task 8: Table on session rows

**Files:**
- Modify: `App/LogView/LogTableView.swift`, `App/LogView/LogView.swift`

**Interfaces:**
- Consumes: `StreamSession.rows` (`count`, subscript, `position(ofRow:)`, `row(forPosition:)`, `row(atOrBefore:)`, `insertedAtFront`, `removedFromFront`, `resetCount`, `isFiltered`), `session.filter`, `session.isFiltering`.
- Behaviour:
  - Every table row maps through `session.rows` instead of `session.store`. Between applies the coordinator maps a table row with the counters it last showed: `currentRow = tableRow + (insertedAtFront − shownInserted) − (removedFromFront − shownRemoved)`; rows outside the current range return nil (blank). A changed `resetCount` makes `entry(forRow:)` return nil until the next apply, which reloads the table.
  - Anchoring by absolute position, replacing the eviction-only offset logic: before an update remember the top visible row's position (and offset) and the selected row's position; after it, scroll so the same position is at the top (`row(forPosition:)`, falling back to `row(atOrBefore:)`, falling back to row 0); when following, scroll to the bottom as today. This covers eviction (rows removed at the front) and rescans (rows inserted at the front).
  - Selection: after a reset, re-select the selected position if it is still a row; otherwise clear the table's selection **without** calling `onSelect(nil)` — the detail pane keeps the entry (§8.1). Evicted selection keeps today's behaviour (cleared, `onSelect(nil)`).
  - Window subtitle: `"\(rows.count.formatted()) of \(store.count.formatted()) messages"` when `session.filter != nil`, plus `" · N dropped"` as today; unchanged otherwise.
  - Empty states (Review Focus 1): store empty → today's overlay; store not empty, filter on, `rows.count == 0`, not filtering → "No Matching Messages" with description "No messages match the current filter."; while `isFiltering` and `rows.count == 0` → no overlay.
- [ ] **Step 1: Implement** the changes. Keep `reloadRowsWithViews` for row shifts; keep the 16 ms rules from the MVP (no `reloadData()` on every update).
- [ ] **Step 2: Build and run the app tests**: `xcodebuild test -project BetterConsole.xcodeproj -scheme BetterConsole -destination 'platform=macOS'` → `** TEST SUCCEEDED **`.
- [ ] **Step 3: Manual check** (record results in the task report): stream This Mac; in a Debug build temporarily apply a filter through `BETTERCONSOLE_PROBE_FILTER` (Task 7) and confirm the subtitle reads "N of M messages", rows match, scrolling up keeps the same message on top while new rows arrive, and a filter matching nothing shows "No Matching Messages".
- [ ] **Step 4: Commit** `feat(app): log table shows the session's filtered rows`.

### Task 9: Filter bar

**Files:**
- Create: `App/Filter/FilterBar.swift`, `App/Filter/BubbleField.swift`, `App/Filter/BubbleView.swift`, `App/Filter/FilterDialogs.swift`
- Modify: `App/LogView/LogView.swift` (bar above the table, below any banner)

**Interfaces:**
- Consumes: `FilterWorkspace`, `FilterLibrary`, `BubbleCodec`, `BubbleLayout`, `BubbleEditing`, `FilterSuggestions`, `session.seenValues`, `session.isFiltering`, `session.filterProgress`, `FilterField.title`, `MatchKind.title`, `FilterCondition.valueProblem`.
- Behaviour, exactly §6 (with the bubble menu and dialogs below):
  - Dropdown: "New Filter", divider, saved filters by name with a checkmark on the device's `basedOn`; title shows the display name plus " (Edited)" when edited.
  - Bubble field: custom SwiftUI flow layout (wraps; up to 3 lines visible, then scrolls), bubbles in `BubbleLayout.ordered` order with "and"/"or" words between them; exclude bubbles show "⊘" and "not" styling; invalid bubbles (`valueProblem != nil`) red with the problem as `.help`; advanced bubbles titled "Advanced rule" with the expression summary as `.help`, offering only Remove. A text field after the last bubble; typing shows `FilterSuggestions.make(for:seen:)` in a popover list; ↑/↓ move, Return picks (first by default), Escape closes; Backspace in an empty field first selects the last bubble, a second Backspace removes it.
  - Bubble menu (click): Field ▸ (all `FilterField` titles), Match ▸ (the field's `allowedMatches`), Include / Exclude, Edit Value… (inline text edit), Remove. Changing the field to one whose matches exclude the current one switches the match to `.is`. Type's Edit Value offers Default/Info/Debug/Error/Fault.
  - Every bubble change → `workspace.setExpression(BubbleCodec.expression(from:), for:)`.
  - "Filtering…" with a small determinate progress view while `session.isFiltering`.
  - Save: enabled when edited, or Untitled with at least one bubble; Untitled → name sheet then `saveAs`; else `save`.
  - "…" menu: Save As…, Rename…, Edit (disabled, `.help("Coming soon")`), Duplicate, Export…, Import…, Delete…; Rename/Duplicate/Export/Delete disabled for Untitled.
  - Dialogs (`FilterDialogs.swift`): name sheet (title "Save Filter" / "Rename Filter", field prefilled, buttons Save/Rename and Cancel, empty name disables the button); unsaved-edits prompt before picking another filter or "New Filter": message `Save changes to “<name>”?`, buttons Save, Discard, Cancel (Save on Untitled goes through the name sheet); delete confirm `Delete “<name>”?` with "This can't be undone." and Delete/Cancel; Import uses an open panel (`.json`, multiple), then an alert listing rejected files and reasons when any were rejected; Export uses a save panel with `<name>.json`; the library's `loadProblem` is shown once as an alert at launch, then acknowledged.
- [ ] **Step 1: Implement** the four files and the `LogView` change.
- [ ] **Step 2: Build and run app tests**: `xcodebuild test -project BetterConsole.xcodeproj -scheme BetterConsole -destination 'platform=macOS'` → `** TEST SUCCEEDED **`.
- [ ] **Step 3: Manual walkthrough** (record each result in the task report): type `cfnet` + Return → Message contains bubble, rows filter; change it to Process is via the menu; two Process bubbles show "or", adding a Type exclude shows "and" and "not"; Backspace twice removes the last bubble; Save on Untitled asks a name and the dropdown shows it; edit → "(Edited)"; pick another filter → Save/Discard/Cancel prompt; switch device in the sidebar → the other device keeps its own filter; quit and relaunch → each device's filter is back; Export, edit the exported file, Import → a second filter "<name> 2"; Import a broken file → rejection alert; Delete → confirm, device becomes Untitled (Edited); Edit is greyed out with "Coming soon".
- [ ] **Step 4: Commit** `feat(app): filter bar with bubbles and saved filters`.

### Task 10: Right-click menu and Copy

**Files:**
- Create: `App/LogView/RowCopy.swift`
- Modify: `App/LogView/LogTableView.swift` (an `NSTableView` subclass for `menu(for:)` and `copy(_:)`), `project.yml` (add `App/LogView/RowCopy.swift` to the test bundle's sources), regenerate the project
- Test: `Tests/BetterConsoleTests/RowCopyTests.swift`

**Interfaces:**
- Consumes: `QuickFilterItems.items(for:)`, `BubbleEditing.adding`, `BubbleCodec`, `FilterWorkspace.setExpression`, `LogColumn.defaultColumns`.
- Produces: `enum RowCopy { static func line(for entry: LogEntry, columns: [LogColumn]) -> String }` — column values joined by tabs, Type as the level's raw value, and the **full** message (not the cell's first line) with newlines replaced by spaces.
- Menu (§7): right-click selects the clicked row, then shows `Copy` (⌘C), `Copy Message`, separator, one `Hide <Field title> '<menuValue>'` per item, separator, the same as `Show …`. Hide → `adding(condition, include: false)`, Show → `include: true`, then `workspace.setExpression`. ⌘C with a selected row = Copy.
- [ ] **Step 1: Write failing test** `RowCopyTests.copyLine`: an entry with a two-line message and nil category → `"16:04:11.584290\tDefault\tWindowServer\tcom.apple.Multitouch\t\tline one line two"` (time via `LogTimestampFormatter` in a fixed time zone set by the test; Type column text is the level's raw value).
- [ ] **Step 2: Run to see it fail**: `xcodebuild test -project BetterConsole.xcodeproj -scheme BetterConsole -destination 'platform=macOS'`.
- [ ] **Step 3: Implement** `RowCopy`, the table subclass, the menu and the actions.
- [ ] **Step 4: Run** → `** TEST SUCCEEDED **`.
- [ ] **Step 5: Manual check** (record in the report): right-click a Mac row → the 8 Hide and 8 Show items with the row's values; an iPhone row has no Activity ID items; Hide Process adds a red-free exclude bubble and the rows update; Show on the same value replaces it; Copy Message pastes the full message.
- [ ] **Step 6: Commit** `feat(app): right-click Hide/Show menu and Copy` (include the regenerated project).

### Task 11: Performance verification

**Files:**
- Create: `Packages/BetterConsoleKit/Tests/BCStreamingTests/FilterPerformanceTests.swift`
- Modify: `docs/RELEASE.md` (§1: add the filtered probe run)

**Interfaces:**
- Consumes: `CompiledFilter`, `StreamSession.setFilter`, `rows`, the probe (`BETTERCONSOLE_PROBE`, `BETTERCONSOLE_PROBE_FILTER`), `scripts/flood.sh`.
- [ ] **Step 1: Write performance tests** (tagged `.tags(.performance)`, skipped unless `BC_PERF=1`): `liveCheckCost` — typical filter (`process is` ×2, `subsystem contains`, `type is` exclude, `message contains`) over 1,000,000 realistic entries; prints ns/entry; expects ≤ 3,700 ns/entry (10 % of a core at 27k/s). `rescan800k` — a session holding 800,000 entries, `setFilter(typical)`; prints wall time; expects ≤ 1 s; also records the longest single main-actor step and expects ≤ 4 ms.
- [ ] **Step 2: Run in Release**: `BC_PERF=1 swift test -c release --package-path Packages/BetterConsoleKit --filter FilterPerformanceTests` → both pass; copy the printed figures into the task report. If either misses, tune (chunk size, needle handling) and rerun before continuing.
- [ ] **Step 3: Probe run**: Release build, `scripts/flood.sh` running, app launched with `BETTERCONSOLE_PROBE=<file>` and `BETTERCONSOLE_PROBE_FILTER=<exported typical filter>` for 60 s; record main-thread blocks over 16 ms and drops. Note in the report whether the screen was locked (the MVP's numbers were taken locked).
- [ ] **Step 4: Update `docs/RELEASE.md` §1** with the filtered probe command.
- [ ] **Step 5: Commit** `test(perf): filter performance checks and filtered probe run`.
