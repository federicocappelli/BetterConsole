# Release procedure

BetterConsole is distributed outside the Mac App Store: a Developer ID–signed, notarized,
stapled app in a DMG. The app is not sandboxed (it runs `log`, `xcrun simctl` and loads
Apple's private MobileDevice.framework), so it can't go through the App Store.

Status (Task 11, 2026-11-13):

| Step | Status |
| --- | --- |
| Release build, ad-hoc signed, launched from a scratch folder; Mac and simulator streaming checked (no USB device was attached) | done |
| Developer ID signing with hardened runtime | **not yet executed**: needs your own Developer ID |
| Notarization (`notarytool`) and stapling | **not yet executed** |
| DMG (`hdiutil`) | **not yet executed** |
| Launch of the notarized copy from `/Applications`, all three device kinds streaming | **not yet executed** |

The project signs ad hoc (`CODE_SIGN_IDENTITY: "-"`, no team). Never put an employer's
certificate or team into this project.

## 1. Throughput check (before every release)

Two tools ship in the repo:

- `scripts/flood.sh [rate] [seconds] [threads] [level]` writes `rate` messages per second
  through `os.Logger` (subsystem `app.betterconsole.flood`, debug level by default). It
  compiles `scripts/flood.swift` once into `$TMPDIR`.
- The app's probe: launched with `BETTERCONSOLE_PROBE=<file>`, it starts streaming this Mac
  by itself and appends one line every 5 s to `<file>`: main run-loop iterations over 16 ms
  and the longest one, table updates and their cost, messages received per second, dropped
  and stored counts, estimated store size and resident memory; every 30 s also one line per
  device session. With `BETTERCONSOLE_PROBE_DEVICES=all` it starts every available device
  instead of only this Mac. Without `BETTERCONSOLE_PROBE` none of this runs.

```sh
xcodegen generate
xcodebuild -project BetterConsole.xcodeproj -scheme BetterConsole -configuration Release \
  -derivedDataPath build/release build
pgrep -fl BetterConsole   # nothing else may run: a second instance doubles the load
BETTERCONSOLE_PROBE=$TMPDIR/probe.txt \
  build/release/Build/Products/Release/BetterConsole.app/Contents/MacOS/BetterConsole &
sleep 3; osascript -e 'tell application id "app.betterconsole.BetterConsole" to activate'
sleep 3; scripts/flood.sh 25000 90 4
osascript -e 'tell application id "app.betterconsole.BetterConsole" to quit'
cat $TMPDIR/probe.txt
```

Pass: received ≥ 20,000 msgs/s, dropped 0 or counting, no iteration over 16 ms, resident
memory levelling off near the "Maximum memory for logs" setting once the store is full. Run
it with the screen unlocked and the window in front: on a locked screen AppKit still lays out
and draws, but the figures exclude compositing. To check the budget, set it before launch
(`defaults write app.betterconsole.BetterConsole maxLogMemoryGB -float 0.5`) and delete it
afterwards (`defaults delete app.betterconsole.BetterConsole maxLogMemoryGB`).

Filtered run: the same, with `BETTERCONSOLE_PROBE_FILTER=<file>` set to a filter exported
from the app (filter bar, Export…). The app applies it to this Mac's session before streaming
and the session line in the probe output says `filter applied, N rows shown` (a file that can't
be read is ignored silently and the line then says `no filter`, so check it). Compare the
figures with an unfiltered run of the same build. Pass criterion for a filtered run: no new
blocks over 16 ms compared with the unfiltered baseline on the same machine (measured at
25,000 msg/s on the development Mac, Release: both runs show 27-49 iterations over 16 ms per
5 s window with the longest 22-50 ms, so the absolute "no iteration over 16 ms" line is not
met even unfiltered; a filter matching half the flood raised the count by ~10 per window and the
longest table update from 2.8 to ~9 ms once the store was full).

```sh
BETTERCONSOLE_PROBE=$TMPDIR/probe.txt BETTERCONSOLE_PROBE_FILTER=$TMPDIR/filter.json \
  build/release/Build/Products/Release/BetterConsole.app/Contents/MacOS/BetterConsole &
```

The speed targets of the filters (rescan of 800,000 entries within 1 s, longest main-actor
step under 4 ms, live checking under 3,700 ns/entry) are checked by
`BC_PERF=1 swift test -c release --package-path Packages/BetterConsoleKit --filter FilterPerformanceTests`.

For hotspots, attach Instruments while the flood runs:

```sh
xcrun xctrace record --template 'Time Profiler' --attach <pid> --time-limit 25s \
  --output $TMPDIR/profile.trace
xcrun xctrace export --input $TMPDIR/profile.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > $TMPDIR/profile.xml
```

## 2. Local release build (ad hoc) — done

```sh
xcodegen generate
xcodebuild -project BetterConsole.xcodeproj -scheme BetterConsole -configuration Release \
  -derivedDataPath build/release build
codesign -dv --verbose=2 build/release/Build/Products/Release/BetterConsole.app
mkdir -p $TMPDIR/bc-release && ditto build/release/Build/Products/Release/BetterConsole.app \
  $TMPDIR/bc-release/BetterConsole.app
open $TMPDIR/bc-release/BetterConsole.app
```

Then stream This Mac and a booted simulator (and a USB device, if one is attached) and quit.
`pgrep -fl 'log stream|simctl'` must show nothing left over from the app.

Checked on 2026-11-13 (Xcode 27.2): `codesign -dv` shows `flags=0x10002(adhoc,runtime)`,
`Signature=adhoc`, `TeamIdentifier=not set`, so this build already runs under the hardened
runtime, and Mac and simulator streaming worked from the copy in a scratch folder (Release
build, `BETTERCONSOLE_PROBE_DEVICES=all`: both sessions streaming, ~330k messages in 35 s, no
`log`/`simctl` children left after quit). Older Xcode versions skip `-o runtime` for ad-hoc
signing (`flags=0x2(adhoc)`); if yours does, the hardened runtime only applies once a real
identity is set (step 3), and step 5's launch check is the first one that exercises it.
Library validation is not enforced for ad-hoc signatures either way, so USB-device
streaming (MobileDevice.framework) must be rechecked in step 5.

## 3. Developer ID signing — not yet executed

Prerequisites: an Apple Developer Program membership in your own name, a "Developer ID
Application" certificate in your login keychain, and an app-specific password for
notarization.

1. In `project.yml`, replace the ad-hoc settings under `settings.base`:

   ```yaml
   DEVELOPMENT_TEAM: "<YOUR_TEAM_ID>"
   CODE_SIGN_STYLE: Manual
   CODE_SIGN_IDENTITY: "Developer ID Application"
   ```

   Keep `ENABLE_HARDENED_RUNTIME: YES` on the app target. No hardened-runtime exceptions
   should be needed: `log` and `xcrun` are separate processes, and MobileDevice.framework is
   signed by Apple, so library validation accepts it. If step 5 shows otherwise, add only the
   exception it proves necessary to `App/BetterConsole.entitlements`.

2. Archive and export:

   ```sh
   xcodegen generate
   xcodebuild archive -project BetterConsole.xcodeproj -scheme BetterConsole \
     -configuration Release -archivePath build/BetterConsole.xcarchive
   cat > build/ExportOptions.plist <<'PLIST'
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0"><dict>
     <key>method</key><string>developer-id</string>
     <key>teamID</key><string><YOUR_TEAM_ID></string>
     <key>signingStyle</key><string>manual</string>
     <key>signingCertificate</key><string>Developer ID Application</string>
   </dict></plist>
   PLIST
   xcodebuild -exportArchive -archivePath build/BetterConsole.xcarchive \
     -exportOptionsPlist build/ExportOptions.plist -exportPath build/export
   codesign -dv --verbose=4 build/export/BetterConsole.app   # flags include 0x10000(runtime)
   codesign --verify --deep --strict --verbose=2 build/export/BetterConsole.app
   ```

## 4. Notarize, staple, DMG — not yet executed

```sh
# Once: store the notarization credentials in the keychain.
xcrun notarytool store-credentials "<YOUR_NOTARY_PROFILE>" \
  --apple-id "<YOUR_APPLE_ID>" --team-id "<YOUR_TEAM_ID>" --password "<APP_SPECIFIC_PASSWORD>"

ditto -c -k --keepParent build/export/BetterConsole.app build/BetterConsole.zip
xcrun notarytool submit build/BetterConsole.zip --keychain-profile "<YOUR_NOTARY_PROFILE>" --wait
xcrun stapler staple build/export/BetterConsole.app

hdiutil create -volname BetterConsole -srcfolder build/export/BetterConsole.app -ov \
  -format UDZO build/BetterConsole-0.1.0.dmg
codesign -s "Developer ID Application" build/BetterConsole-0.1.0.dmg
xcrun notarytool submit build/BetterConsole-0.1.0.dmg --keychain-profile "<YOUR_NOTARY_PROFILE>" --wait
xcrun stapler staple build/BetterConsole-0.1.0.dmg
spctl -a -vv -t install build/BetterConsole-0.1.0.dmg
```

If a submission is rejected, `xcrun notarytool log <submission-id> --keychain-profile
"<YOUR_NOTARY_PROFILE>"` says why.

## 5. Launch check of the notarized copy — not yet executed

Open the DMG, drag BetterConsole to `/Applications`, launch it from there, and check:

- This Mac streams (Pause, Start, Clear, Now).
- A booted simulator streams.
- A USB-connected iPhone streams (MobileDevice.framework loads under library validation).
- `spctl -a -vv /Applications/BetterConsole.app` reports `source=Notarized Developer ID`.
- After quitting, `pgrep -fl 'log stream|simctl'` shows nothing left over.

Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` before each release.
