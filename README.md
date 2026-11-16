# BetterConsole

A macOS log viewer for developers: live logs from your Mac, booted simulators and USB‑connected
iPhones, with filtering you can read, save, share and edit.

BetterConsole does one thing Console.app does, streaming logs, and tries to do it much better.
It has no crash, spin or diagnostic reports, and no log archives. It's just the live log stream,
plus a filter system built for people who look at logs every day.

## Why I built it

I spend a lot of my day in Console.app, watching logs from the Mac I'm working on, from
simulators and from a phone on my desk. Streaming works well. Filtering is where the time goes:

- **Queries can't be kept or shared.** I build the same filters by hand again and again. A
  saved search lives inside Console, so I can't send it to a colleague, keep it in a repo, or
  edit it in a text editor.
- **The search field is a single line.** Anything beyond three tokens scrolls out of sight,
  and I can't see the whole query at once.
- **It's never clear how tokens combine.** Do two tokens mean AND or OR? Does a third one
  change that? The field doesn't say, so I end up guessing and re-reading the results.
- **Saved searches are opaque.** I can't see what a saved search contains, or change it,
  without applying it first.
- **No real rules.** Something like "(this process AND this subsystem) but not debug
  messages" is hard or impossible to express.

Console does get two things right: the token ("bubble") field, and right‑clicking a message to
show or hide everything like it. BetterConsole keeps both and builds the rest around them.

## How it's better than Console

| | Console.app | BetterConsole |
|---|---|---|
| How tokens combine | Implicit | Shown between every pair of bubbles: **or** for the same field, **and** across fields, **not** for excludes |
| Long filters | One scrolling line | Bubbles wrap onto several lines |
| Saved filters | Hidden until applied | A dropdown of named filters; "(Edited)" when what you see differs from what's saved |
| Sharing | Not possible | Export and import filters as plain JSON files |
| Right‑click Hide/Show | Yes | Yes: Process, PID, Library, Thread ID, Subsystem, Category, Type, Activity ID |
| Memory | No setting | A single cap you set (default 4 GB); oldest messages go first |

On top of that:

- **Each device keeps its own filter.** Your Mac, a simulator and a phone can each have a
  different filter, and each comes back when you relaunch.
- **Changing a filter on a busy stream doesn't freeze anything.** Messages already in memory
  are re-checked in the background, newest first, so the rows you're looking at appear first.
  Removing a filter brings every message back, because nothing is thrown away.
- **Heavy load is visible.** It keeps up at tens of thousands of messages a second; anything
  that can't be kept is dropped and **counted** in the window's subtitle, never lost silently.

### Filtering in practice

```
[ DDG Errors (Edited) ▾ ] [ PROCESS is DuckDuckGo ] or [ PROCESS is Safari ] and [ ⊘ TYPE is debug ]  type here…  [Save] [⋯]
```

- **Type, press Return, get a bubble.** Suggestions appear as you type, including process,
  subsystem, category and library names seen in this device's logs. "Message contains" is
  the default.
- **Click a bubble** to change its field, its match type (contains, is, starts with, regex) or
  whether it includes or excludes.
- **Right‑click any message** to hide or show everything from the same process, subsystem,
  category, thread and so on.
- **Save, Save As, Rename, Duplicate, Export, Import, Delete** are in the bar's "…" menu.
- Matching ignores case. An invalid regex shows up as a red bubble and is ignored until you
  fix it, so it never silently breaks the filter.

A saved filter is a small JSON file, readable and editable by hand:

```json
{
  "format": "betterconsole.filter",
  "version": 1,
  "name": "DDG Errors",
  "expression": { "all": [
    { "any": [ { "condition": { "field": "process", "match": "is", "value": "DuckDuckGo" } } ] },
    { "not": { "condition": { "field": "type", "match": "is", "value": "debug" } } }
  ] }
}
```

`format`, `version` and `id` are optional when importing; `name` and `expression` are required,
and every field and match type is checked at import, so a filter that imports always works.
The format is an expression tree (all / any / not), so richer rules than the bar can show
already round‑trip. A visual editor for grouped rules is planned (see Roadmap).

## Sources

- **This Mac**, through `log stream`.
- **Booted simulators**, through `xcrun simctl spawn <device> log stream`. They appear and
  disappear as you boot and shut them down.
- **iPhones and iPads connected by USB**, through Apple's private `MobileDevice.framework`, the
  same path Console.app uses. This code lives in a single module (`BCMobileDevice`) behind a
  protocol, so the transport can be swapped later.

Unplugging a device keeps its row and its logs. Plug it back in and streaming resumes on its own.

## Requirements

- macOS 26 or later
- Xcode 27 with the iOS platform installed (for simulators)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or later, if you change `project.yml`

## Building

```sh
git clone <this repo>
cd BetterConsole
xcodegen generate            # only needed after editing project.yml
open BetterConsole.xcodeproj
```

Build and run the `BetterConsole` scheme. The project signs ad hoc, so no developer account
is needed to run it locally.

Tests:

```sh
swift test --package-path Packages/BetterConsoleKit
xcodebuild test -project BetterConsole.xcodeproj -scheme BetterConsole -destination 'platform=macOS'
```

Performance checks (Release build, skipped by default):

```sh
BC_PERF=1 swift test -c release --package-path Packages/BetterConsoleKit --filter FilterPerformanceTests
```

`docs/RELEASE.md` describes the throughput probe and the `scripts/flood.sh` load generator.

## How it's put together

```
App/                         SwiftUI app shell, AppKit log table, filter bar, settings
Packages/BetterConsoleKit/
  BCModel                    LogEntry and decoding of `log stream` NDJSON
  BCStore                    in-memory ring buffer and the global memory budget
  BCTransport                device discovery and process-based log transports (Mac, simulators)
  BCMobileDevice             the only code that touches MobileDevice.framework
  BCStreaming                per-device sessions: bounded queue, filtering, match index, rescans
  BCFilter                   filter model, evaluation, JSON format, bubbles, saved-filter library
```

- **Logs live in memory only.** Nothing is written to disk. The memory cap (Settings) bounds
  how much is kept.
- **The log list is an `NSTableView`** with fixed row heights, cell reuse and batched updates,
  because SwiftUI's `Table` can't keep up with this insert rate.
- **Filtering never blocks the window.** New messages are checked off the main thread
  before they reach the screen. A filter change re-checks stored messages in the background,
  newest first, while the list fills in progressively.
- **Measured on the development Mac (Release build):** checking a new message against a typical
  five-bubble filter takes about 0.7 µs. Re-checking 800,000 stored messages takes about 0.65 s,
  in steps of under 2 ms on the main thread.

## Privacy

BetterConsole makes no network connections of its own. Device discovery is USB only, so it
never asks for Local Network access. Logs stay in memory and are gone when you quit. Saved
filters are stored in `~/Library/Application Support/BetterConsole/` and leave that folder
only when you export them.

## Limitations

- **iOS devices use a private Apple framework.** It works today and is what Console.app uses,
  but Apple can change it in any release.
- **No log archives, no reports.** BetterConsole streams live logs only.
- **The app is not sandboxed.** It needs to run `log` and `simctl` and to load
  `MobileDevice.framework`, so it can't ship through the Mac App Store.
- `<private>` values in messages are redacted exactly as Console.app shows them.

## Roadmap

- A grouped‑rule editor for filters like `(A and B) when C ≠ D`: a visual builder and an
  expandable text form kept in sync.
- Column customisation and a configurable time format.
- Exporting selected messages to a file, and reopening that file for filtering later.

## Contributing

Issues and pull requests are welcome. Please run both test suites before opening a PR, and
keep anything that touches `MobileDevice.framework` inside `BCMobileDevice`.

## License

Not yet chosen. Until a license is added, all rights are reserved.
