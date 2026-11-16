# BetterConsole — Design (Phase 3: filter bar, saved filters, right-click Hide/Show)

Builds on `2026-11-13-betterconsole-mvp-design.md` (the MVP spec). Where this
document is silent, the MVP spec still holds.

## 1. Intent

Filtering is why BetterConsole exists. Console.app's filtering frustrates the
user in specific ways, and this phase fixes the everyday part of it:

- Queries are hand-built and cannot be exported, shared or edited on their own.
- The query field is small and puts everything on one line.
- It is unclear whether tokens combine with AND, OR or NOT.
- A saved search cannot be seen or edited until it is applied.

What Console gets right, and this phase keeps: the token ("bubble") field, and
right-click on a row to show or hide messages like it.

Success: the user can narrow a busy stream to what they care about in a few
keystrokes or clicks, see exactly what the filter does, keep it as a named
filter, share it as a file, and never wait on a frozen window while doing so.

## 2. Scope of this phase

Goals:

- A **filter bar** above the log list with, from the left: a saved-filter
  dropdown, a bubble field, a Save button and a "…" menu.
- **Bubbles**: typed text becomes a bubble; each bubble has a field, a match
  kind, a value and include/exclude. The way bubbles combine is fixed and
  always visible (§5.2).
- **Saved filters**: a shared library of named filters, kept privately by
  the app, with Save, Save As, Rename, Duplicate, Export, Import and Delete.
  Export and Import of JSON files are the only way filters leave or enter the
  app (§9).
- **Per-device filters**: each device in the sidebar has its own current
  filter, remembered across launches.
- **Right-click menu** on a log row, matching Console.app: Copy, Copy Message,
  then a Hide block and a Show block (§7).
- Filtering that stays fast while streaming (§8).

Non-goals for this phase (next round, must not be blocked):

- The **grouped-rule editor** (visual tree builder plus a text form kept in
  sync) for rules like `(X AND Y) when B != C`. The "…" → Edit item exists but
  is **greyed out** this round (user decision).
- Column customisation, time-format setting, export/import of log messages.
- Free-text search separate from filtering (a Message-contains bubble covers it).

Anti-goals (a failure even if it "works"):

- The window stalls while a filter is applied or changed, or while streaming
  with a filter on.
- Hidden messages are lost: removing a bubble must bring them back.
- The screen suggests a different AND/OR/NOT meaning than the filter applies.
- A saved filter changes or disappears without the user saving or deleting it.

## 3. Decisions

| Decision | Choice | Source |
|---|---|---|
| Bar layout | Dropdown · bubble field · Save · "…" menu, left to right, above the log list | user |
| Combination rule | Same field → OR; different fields → AND; exclude → NOT; connector words always shown between bubbles (option A) | user |
| Complex rules | Grouped editor next round; "…" → Edit greyed out now; JSON format already supports groups | user |
| Filter scope | Each device keeps its own current filter | user |
| Right-click menu | Hide/Show for Process, PID, Library, Thread ID, Subsystem, Category, Type, Activity ID, as in Console.app (screenshot) | user |
| Typing a bubble | Suggestion list as you type; default "Message contains"; values seen in this device's logs offered | Claude, agreed |
| Matching | Case-insensitive; match kinds contains / is / starts with / regex | Claude, agreed |
| Unsaved edits | Dropdown shows "Edited"; Save writes it; switching filters with edits asks Save / Discard / Cancel | Claude, agreed |
| Storage | The library is private to the app and never edited from outside while the app uses it; filters leave and enter only through Export and Import of JSON files; validation happens at import, and a file that cannot be parsed is rejected | user |
| Starter filter | "Errors and Faults" created on first launch, deletable | Claude, agreed |
| Filter applies to | Messages already in memory and new ones; nothing is discarded | Claude, agreed |
| Count | Window subtitle "1,204 of 45,348 messages" while a filter is on | Claude, agreed |
| Right-click extras | Copy and Copy Message at the top; items with no value are omitted | Claude, agreed |
| Device filter across launches | Remembered, keyed by device ID, including unsaved edits | Claude, agreed |

## 4. Approaches considered (how the list gets filtered)

- **A. Keep every message; each device keeps a list of matching rows
  (chosen).** The store is unchanged. Each session keeps an index of the
  positions of matching messages; the table shows the index instead of the
  store. New messages are checked as they arrive; a filter change re-checks the
  store in the background. Cheap in memory (one integer per match) and nothing
  is lost.
- **B. Filter in the stream and drop non-matching messages** (like
  `log stream --predicate`). Cheapest at run time, but removing a bubble cannot
  bring hidden messages back. Rejected: breaks an anti-goal.
- **C. A second store per device holding only matching messages.** Same result
  as A with more memory, and two stores to keep in step under eviction.
  Rejected.
- **D. SQLite with full-text search.** Ruled out by the MVP spec; slows
  ingestion, and only pays off for history far larger than the memory cap.

## 5. Filter model

### 5.1 Expression tree (module `BCFilter`, no AppKit)

A filter is a tree, so the next round's editor needs no format change:

- `Condition`: `field`, `match`, `value`, plus `isEnabled` (reserved; always
  true this round).
- `Expression`: `.condition(Condition)`, `.all([Expression])` (AND),
  `.any([Expression])` (OR), `.not(Expression)`.
- `Field` and what each reads from `LogEntry`:

| Field | Reads | Match kinds | Menu label in the right-click menu |
|---|---|---|---|
| Process | `process` | contains, is, starts with, regex | Process |
| PID | `pid` | is | PID |
| Library | last path component of `senderImagePath` | contains, is, starts with, regex | Library |
| Thread ID | `threadID` | is (accepts `0x…` hex or decimal) | Thread ID (shown as `0x…` hex) |
| Subsystem | `subsystem` | contains, is, starts with, regex | Subsystem |
| Category | `category` | contains, is, starts with, regex | Category |
| Type | `level` | is (fixed list: Default, Info, Debug, Error, Fault) | Type (lower-case value, as Console) |
| Activity ID | `activityID` | is | Activity ID |
| Message | `message` | contains, is, starts with, regex | — |

- Text matching ignores case. Regex uses `NSRegularExpression` semantics with
  case-insensitive option.
- A missing value (no subsystem, no activity ID) never matches a condition, so
  an include on it fails and an exclude on it passes.
- An invalid regex or a non-numeric PID makes that bubble **invalid**: it is
  drawn red with the error as a tooltip and is left out of the filter until
  fixed. It is still saved as typed.

### 5.2 Bubbles and the tree ("bar shape")

The bar edits a flat list of bubbles. A list of bubbles maps to and from one
canonical tree shape:

```
all(
  any(include bubbles on field F1…),   // one any() per field, fields in first-appearance order
  any(include bubbles on field F2…),
  not(exclude bubble 1),
  not(exclude bubble 2), …
)
```

- The bar **displays bubbles in this order**: include bubbles grouped by field
  (fields in the order they first appeared), then exclude bubbles. Between two
  bubbles it shows **"or"** when both are includes on the same field, otherwise
  **"and"**. Exclude bubbles are drawn with a strike or "⊘" style and labelled
  "not". The words on screen therefore always state the applied rule.
- An empty bubble list means "no filter": every message shows.
- A tree that is not in bar shape (from an imported file or, later, the
  editor) is shown as **one "Advanced rule" bubble** that summarises it in its
  tooltip. It can be removed but not edited this round. Other bubbles can sit
  next to it and AND with it.
- **Reading a tree into bubbles** (Claude's call), leniently:
  - The root is treated as `all(...)`; any other root is wrapped as one child.
  - Each child of the root becomes bubbles where it can:
    - a bare condition → one include bubble;
    - `any(...)` of conditions on one field → include bubbles on that field;
    - `not(condition)` → one exclude bubble;
    - a nested `all(...)` is flattened into the root;
    - anything else (an `any` mixing fields, `not(any(...))`, deeper nesting)
      → **one Advanced rule bubble per such child**.
- **Writing bubbles to a tree**: `all(<advanced subtrees in their order>,
  any(...) per field, not(...) per exclude)`. Reading what was written gives
  back the same bubbles, so a filter never degrades into Advanced bubbles by
  being saved and reopened.
- Imported files may be hand-written, so the lenient reading above applies
  to them. Anything the reading cannot understand is rejected at import
  (§5.3), never turned into a bubble.

### 5.3 Export file format

Export writes, and Import reads, one filter per file, UTF-8 JSON (the app's
private library may store filters however the builder likes):

```json
{
  "format": "betterconsole.filter",
  "version": 1,
  "id": "6F1C…",
  "name": "DDG Errors",
  "expression": { "all": [
    { "any": [ { "condition": { "field": "process", "match": "is", "value": "DuckDuckGo" } } ] },
    { "not": { "condition": { "field": "type", "match": "is", "value": "debug" } } }
  ] }
}
```

- Field and match identifiers are stable lower-case strings (`process`, `pid`,
  `library`, `thread`, `subsystem`, `category`, `type`, `activity`,
  `message`; `contains`, `is`, `startsWith`, `regex`).
- **All validation happens at import.** Import rejects the whole file, with an
  alert naming the file and the reason, when it:
  - is not valid JSON, is over 1 MB, or is nested deeper than 32 levels;
  - has a different `format`, or a `version` higher than this build knows;
  - has a missing or empty `name`, or no `expression`;
  - contains an unknown field or match identifier, a pair §5.1 does not allow
    (`pid` + `regex`, `type` + `contains`), or a Type value outside the fixed
    list.
  Unknown extra keys are ignored. A filter that passes import is always
  readable from then on, so nothing after import re-validates it.
- An invalid regex or non-numeric PID is a value problem, not a format one: it
  imports and shows as an invalid (red) bubble, exactly as if typed.
- `isEnabled` is reserved: import accepts only `true` or a missing key.

## 6. Filter bar

```
[ DDG Errors (Edited) ▾ ] [ PROCESS is DuckDuckGo ] or [ PROCESS is Safari ] and [ ⊘ TYPE is debug ]  type here…   [Save] [⋯]
```

- Sits above the log list, below any banner, and spans the log pane's width.
  The bubble field grows to fill the space and wraps onto more lines when
  bubbles do not fit (up to a few lines, then scrolls), instead of one long
  line.
- **Dropdown**: "New Filter", a separator, then saved filters by name with a
  check on the one the device's current filter is based on. The selected title
  shows "(Edited)" when the current bubbles differ from the saved file. "New
  Filter" gives an empty, unsaved "Untitled".
- **Typing**: a text cursor sits after the last bubble. As the user types, a
  suggestion list opens under the cursor:
  - First line "Message contains "<text>"" (the Return default).
  - Then Process / Subsystem / Category / Library values **seen in this
    device's logs** that contain the text (a few per field), each as an "is"
    bubble.
  - Then "Subsystem contains …", "Category contains …", "Process contains …".
  - Arrow keys move, Return picks, Escape closes the list. Backspace in an empty
    cursor position selects, then removes, the last bubble.
- **Bubble menu** (click a bubble): field, match kind, include/exclude, edit
  value, remove. Type offers its fixed list.
- **Save**: enabled when the filter is Edited, or Untitled with at least one
  bubble. On Untitled it asks for a name (as Save As).
- **"…" menu**: Save As…, Rename…, Edit (greyed out, tooltip "Coming soon"),
  Duplicate, Export…, Import…, Delete… (confirms; cannot be undone).
  Items that do not apply to Untitled are disabled.
- **Switching filters with unsaved edits** asks Save / Discard / Cancel. Picking
  "New Filter" does the same.

## 7. Right-click menu on a log row

Right-click targets the clicked row (and selects it, as Console does).

```
Copy                         ⌘C
Copy Message
─────────────
Hide Process 'Console'
Hide PID '20368'
Hide Library 'CoreFoundation'
Hide Thread ID '0xa6fc7'
Hide Subsystem 'com.apple.defaults'
Hide Category 'User Defaults'
Hide Type 'debug'
Hide Activity ID '0'
─────────────
Show Process 'Console'
…same items as Show…
```

- **Copy** copies the row as one line of tab-separated column values; **Copy
  Message** copies the full message. ⌘C with a selected row does Copy.
- **Hide** adds an exclude "is" bubble for that value; **Show** adds an include
  "is" bubble. The device's filter becomes Edited.
- Items whose value is missing are omitted (iPhone messages have no Activity
  ID; many have no subsystem). Activity ID 0 is shown, as in Console.
- Adding a bubble identical to an existing one does nothing. Adding the
  opposite of an existing identical bubble (Show when a Hide exists) replaces
  it.
- Long values are truncated in the menu title (middle ellipsis, ~60
  characters); the bubble gets the full value.

## 8. Filtering engine

### 8.1 Per-session match index

- Each `StreamSession` gets a **match index**: the absolute positions of
  matching entries, oldest first. Absolute position = `store.removedCount +
  index`, so positions survive eviction without rewriting.
- With no filter there is no index and the table maps rows straight to the
  store, as today.
- **Eviction** drops index entries below `store.removedCount` from the front.
  **Clear** empties it.
- The table maps row `r` to `store[index[r] - removedCount]`. Selection,
  scroll anchoring and follow-the-bottom keep their current behaviour, applied
  to index rows. The "row evicted since shown" bookkeeping uses absolute
  positions.
- Memory for the index is not counted against the log memory budget (8 bytes
  per match; ~6 MB at 800k matches).
- **Selection when the filter changes** (agreed): if the selected entry no
  longer matches, the table's selection clears but the detail pane keeps
  showing that entry until the user selects another row. If it still matches,
  it stays selected on its new row (found by binary search of its absolute
  position in the index).
- **Scroll position during a rescan** (Claude's call): when following the
  bottom, keep following. Otherwise keep the **same entry** at the top of the
  visible area as rows are inserted above it (the same anchoring the eviction
  path does, in the other direction). If that entry no longer matches, anchor
  to the nearest older match.

### 8.2 New messages

- New entries are checked against the device's compiled filter **off the
  main thread**, before the main-actor drain, and arrive tagged with the
  filter generation they were checked against.
- On drain, entries checked against the current generation are appended to the
  index directly. Entries checked against an older generation are re-checked
  (they are covered by the rescan described next, or re-checked in bounded
  amounts on the drain; the builder picks, within the main-thread budget).
- The main-thread budget for the whole drain (store append, index append,
  table update) stays under 16 ms per frame at the MVP's throughput target.

### 8.3 Filter changes

- Any change (bubble added/removed/edited, saved filter picked, right-click
  Hide/Show) compiles a new filter, bumps the generation and starts a
  **rescan** of the store in the background. A newer change cancels the
  running rescan.
- The rescan works **from newest to oldest**, so the rows at the bottom (where
  a following user is looking) appear first. Results are published to the
  table progressively (at the table's normal update rate).
- While it runs, the filter bar shows a small "Filtering…" progress indicator.
- Each main-thread step of the rescan (taking a chunk of entries from the
  store, publishing results) stays under 4 ms. Eviction and Clear during a
  rescan must leave the index correct.
- Target: rescanning 800,000 entries with a typical filter (five bubbles,
  contains/is) finishes within 1 second on the development Mac.

### 8.4 Compilation

- The tree is compiled once per change into an evaluator that does not
  allocate per entry: lower-cased needles prepared once, regexes compiled once,
  Type and numeric values parsed once, invalid bubbles dropped.
- Live checking at ~27,000 messages a second must cost under 10 % of one core
  for a typical filter.

### 8.5 Suggestion values

- Each session keeps the distinct Process, Subsystem, Category and Library
  values it has seen (capped at 5,000 per field; past the cap new values are
  not added). Updated on drain. Used only for suggestions.

## 9. Saved filters and per-device state

- **Library** (user decision): private to the app, stored under
  `~/Library/Application Support/BetterConsole/` and never shown to the user,
  in a format of the builder's choosing. The app reads it once at launch and is
  the only writer while running; it never watches it or re-reads it. Writes
  are atomic. If the library cannot be read at launch (damaged by hand), the
  app moves it aside as a backup, starts with an empty library and shows a
  one-time alert saying so.
- **Import** (open panel, one or more `.json` files) validates each file
  (§5.3) and adds the ones that pass as new filters; rejected files are
  listed in one alert with their reasons. An imported filter always gets a
  new id; a clashing name gets " 2", " 3", …. **Export** writes the selected
  filter through a save panel. Neither links the file to the library: editing
  an exported file changes nothing until it is imported again.
- **Starter filter**: "Errors and Faults" (`any(Type is error, Type is
  fault)`) is written on first launch only; deleting it is permanent.
- **Per-device state**, stored in `UserDefaults` as JSON keyed by device ID:
  the id of the saved filter it is based on (or none), the current bubble
  tree, and whether it is Edited. Restored when the device's session is
  created.
- **Library changes vs devices**:
  - A saved filter is re-saved from one device: every other device based on it
    **without** edits picks up the new version; devices with edits keep their
    edits and stay Edited.
  - A saved filter is deleted: devices based on it keep their bubbles and
    become Untitled (Edited).
  - Renamed: devices based on it show the new name.
  - **Save As** creates a new filter; only the current device switches to it.
    Other devices based on the original are untouched. **Duplicate** (Claude's
    call, as macOS document Duplicate) creates "<name> copy" and switches the
    current device to the copy, carrying any unsaved edits into it unsaved
    (Edited); the original file is unchanged.
- "Edited" is a stored per-device flag, set by any bubble change and cleared
  by Save, Discard or picking a filter. A device whose stored filter id no
  longer exists in the library at launch becomes Untitled (Edited).

## 10. Testing

Unit tests (Swift Testing) in `BetterConsoleKit`:

- `BCFilter`: every field × match kind; case-insensitivity; missing values for
  include and exclude; invalid regex and PID marked invalid and excluded;
  bubbles ↔ bar-shape tree round trip; non-bar-shape tree detected; export
  → import round trip; import rejects each case in §5.3 (malformed JSON,
  wrong format, newer version, too large, too deep, missing name or
  expression, unknown field or match, disallowed pair, bad Type value,
  `isEnabled: false`) and accepts an invalid regex as an invalid bubble.
- Match index: append, eviction from the front, Clear, mapping rows to entries
  across eviction.
- Driven end to end through a real `StreamSession` with a fake transport:
  - filter on before streaming; filter added while streaming; filter removed
    (all messages back); filter A → B → A while streaming;
  - filter change while a rescan is running (only the latest wins);
  - eviction and Clear during a rescan;
  - entries checked against an old generation arriving after a change;
  - device disconnect and reconnect keep the device's filter.
- Library: save, save as (only the current device switches), rename,
  duplicate (current device moves to the copy with its edits), delete, import
  clashes, starter filter written once, re-save propagating to un-edited
  devices only, delete turning devices Untitled, per-device state restored
  across a simulated relaunch; a damaged library at launch moved aside with
  an empty library; editing an exported file does not change the library.
- Bubbles ↔ tree: the lenient reading rules in §5.2, Advanced subtrees next
  to plain bubbles surviving save and reload.
- Table mapping: selection kept or cleared on filter change; same entry kept
  at the top while a rescan inserts rows above it.
- Performance tests for §8.3 and §8.4 targets (Release build, recorded in the
  test output, not a hard CI gate).

App tests: bubble ordering and connector words; right-click menu items for a
Mac row and an iPhone row (no Activity ID); Hide then Show on the same value
replaces the bubble.

Manual: stream this Mac under `scripts/flood.sh` and change filters
repeatedly; check the main-thread probe stays under budget.

## 11. Left to the builder

- Whether the bubble field is a custom SwiftUI view or AppKit; `NSTokenField`
  cannot draw the "and"/"or" words between tokens, so a custom view is the
  expected route.
- The exact hand-off between off-main checking and the drain (§8.2), chunk
  sizes for the rescan, and how evaluation reads entries off the main actor.
- Suggestion ranking and how many values per field.
- Exact visual styling of bubbles, connector words and the Edited marker,
  following the system look.
