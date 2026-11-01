# Stratum 10 Blueprint — Attach, catalog, delete old

Builds on S9 as its blueprint defines it: `Session` (`attached`, `failures`, `toggle`, `observe`, `core`), `Target`, `Permissions`, `Row` (with `on:`), `MenuBar` (rewritten here), `Rig`/`FakePermissions`/`Counters`/`Gate` (`AppRig.swift`), `dotColor`, `Boom`, existing `FailingSource(base:failAt:)`, S7's `eventually`, `Launch` and `AppHarness.run`, S8's `MicSource`. Source end and failure handling already live in `Session` (S9 tests 9, 10); this stratum adds their menu face.

# Uncertainties squashed

1. **Window listing is the spike's.** `SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)`, `.windows`, `windowLayer`, `title`, `owningApplication?.applicationName` / `.bundleIdentifier` (`spike/Sources/Probe/main.swift:289-297`); `SCRunningApplication.bundleIdentifier` and `.applicationName` are non-optional (`:70`). Same Screen Recording grant as capture (DECISIONS).
2. **`.common` timers, probed** (`/tmp/te-s9-probe/main.swift`): with the loop spun only in `.eventTracking` (an open menu) for 1 s, a `.common` timer at 0.1 s ran its `Task` 4 times, a `.default` timer 0 times: the test is falsifiable by a `.default` mutant. Main-queue `Task`s drain slowly while tracking, so tests assert "within 3 s", never a count. The open-menu test is a synchronous `@MainActor` method: an `async` test is itself a main-actor job and may not run other main-actor jobs inside a nested loop spin.
3. **A failing flush cannot leave a tail.** `TranscriptStore.commit` clears the tail and bumps the epoch (`TranscriptStore.swift:79-80`) before the write that can throw (`:82`), and a late provisional is then dropped by the epoch guard. What is wrong is `SourcePipeline.run`'s ending: when the final `flush()` throws, `offer.finish()` and `live.value` are skipped and the `live` task waits forever on `latest`. One shared ending fixes it (below). It has no observable effect, so no test can fail on it; the Pipeline and Live suites and review cover it.
4. **Making a commit throw without a seam: `RLIMIT_FSIZE`.** Probed (python3): with the soft limit at a file's current size and `SIGXFSZ` ignored, the next `write` fails with `EFBIG`; restoring the limit lets writes resume. `chflags uchg` does not stop writes through an open descriptor (rejected).
5. **Identity is the bundle id.** Rows route on `Target.id`; all of an app's rows check together and a click on any detaches. An attached app the SCK list no longer has keeps a row labelled with its tag. Tag = `String(title.prefix(5))`, untrimmed; `render` trims (`Render.swift:30`).
6. **Reasons have two owners by kind.** Catalog failures are the catalog's state (a disabled row in the submenu). Source failures are `Session.failures` (menu and overlay bar). Delete failures are `Session.deleteError` (menu only).
7. **`deleteOld` without a current engine** removes every `*.jsonl` (stopped means no current file); only `*.jsonl` is touched; the directory is created first; file names are compared, not URLs (`/var` and `/private/var` spell one file two ways).
8. **The catalog publishes only on change** (`(windows, error)` compared), so an open menu or the font slider is not torn down every 5 s; test 4 observes it through submenu identity.
9. **Settled at build** (a red is a finding): (a) SCK lists a TextEdit window with its file name as title; (b) a submenu rebuilt while the menu is open; (c) the rlimit window contains no other file write of the process (a stray failure fails loudly and is reported, not skipped), and `FileHandle.write(contentsOf:)` throws on `EFBIG`; (d) `Verify`'s `windows` op awaits SCK from the top-level task without a run-loop pump (S7 item 5 saw `NSWorkspace` notifications arrive there).

# Blueprint

New: `Sources/TEUI/WindowCatalog.swift`, `Tests/TECoreTests/AttachTests.swift`. Rewritten whole: `Sources/TEUI/MenuBar.swift`. Edited: `Sources/TEUI/{AppController,Verify}.swift`, `Sources/TECore/{TranscriptStore,SourcePipeline}.swift`, `Sources/TranscribeEverything/main.swift`, `Tests/TECoreTests/{AppRig,StoreTests}.swift`. Nothing else.

## `Sources/TECore/SourcePipeline.swift` (edit: the end of `run()` only)
Replace everything from `do {` (the chunk loop) to the end of `run()` so both endings share one tail:
```swift
let failure: Error?
do {
    for try await c in chunks { /* the loop body, unchanged */ }
    try await flush()
    failure = nil
} catch {
    try? await flush()   // a failed source still commits its open segment; a failed final flush has already cleared `open`
    failure = error
}
offer.finish()
let tails = await live.result
if let failure { throw failure }
try tails.get()
```
`flush()` stays as is.

## `Sources/TECore/TranscriptStore.swift` (add)
```swift
/// Removes every session file under the root except `current`'s; with no current engine start, all of them. Foreign files stay.
public static func deleteOld(in paths: Paths, except current: URL?) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
    for f in try fm.contentsOfDirectory(at: paths.transcripts, includingPropertiesForKeys: nil)
    where f.pathExtension == "jsonl" && f.lastPathComponent != current?.lastPathComponent { try fm.removeItem(at: f) }
}
```

## `Sources/TEUI/WindowCatalog.swift`
```swift
import Foundation
import ScreenCaptureKit

@MainActor public final class WindowCatalog {
    public struct Window: Codable, Hashable, Sendable {
        public let bundleId: String, app: String, title: String
        public init(bundleId: String, app: String, title: String) { /* assign */ }
    }
    public private(set) var windows: [Window] = []
    public private(set) var error: String?
    var onChange: (() -> Void)?
    private let permissions: any Permissions, fetch: () async throws -> [Window]
    private var timer: Timer?

    /// Refreshes now, then every `every` seconds (DECISIONS: launch and every 5 s).
    public init(permissions: any Permissions, every: TimeInterval = 5, fetch: @escaping () async throws -> [Window] = WindowCatalog.system) {
        self.permissions = permissions
        self.fetch = fetch
        Task { await refresh() }
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)   // an open menu runs the loop in .eventTracking, which .default timers never see
        timer = t
    }
    deinit { timer?.invalidate() }

    /// No SCK call without Screen Recording. A failed call keeps the last list and shows why. Publishes only a change.
    public func refresh() async {
        let next: ([Window], String?)
        if !permissions.granted(.screenRecording) { next = ([], "Screen Recording not granted") }
        else { do { next = (try await fetch(), nil) } catch { next = (windows, "Window list: \(error)") } }
        guard next != (windows, error) else { return }
        (windows, error) = next
        onChange?()
    }

    public nonisolated static func system() async throws -> [Window] {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false).windows.compactMap { w in
            guard w.windowLayer == 0, let title = w.title, !title.isEmpty, let app = w.owningApplication, !app.bundleIdentifier.isEmpty else { return nil }
            return Window(bundleId: app.bundleIdentifier, app: app.applicationName, title: title)
        }
    }

    /// Distinct windows, one group per app, in menu order.
    public nonisolated static func groups(_ ws: [Window]) -> [[Window]] {
        Dictionary(grouping: Set(ws), by: \.bundleId).values
            .map { $0.sorted { $0.title < $1.title } }
            .sorted { ($0[0].app, $0[0].bundleId) < ($1[0].app, $1[0].bundleId) }
    }
}
```
Layer 0 and a non-empty title are the spike's filter; the overlay panel (floating level) and status items are never layer 0.

## `Sources/TEUI/AppController.swift` (add two members at the end of `Session`)
```swift
public private(set) var deleteError: String? { didSet { notify() } }

public func deleteOld() {
    deleteError = nil
    do { try TranscriptStore.deleteOld(in: paths, except: core?.store.file) } catch { deleteError = "Delete old transcriptions: \(error)" }
}
```

## `Sources/TEUI/MenuBar.swift` (rewrite whole; S9's is abandoned)
```swift
import AppKit

@MainActor public final class MenuBar {
    public let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let session: Session, catalog: WindowCatalog, settings: [NSMenuItem]

    /// `settings` are items owned elsewhere (the overlay's Hide/Show, the font slider); they sit right after the Attach row.
    public init(session: Session, catalog: WindowCatalog, settings: [NSMenuItem]) {
        self.session = session
        self.catalog = catalog
        self.settings = settings
        item.menu = NSMenu()
        session.observe { [weak self] in self?.render() }
        catalog.onChange = { [weak self] in self?.render() }
        render()
    }
    deinit { NSStatusBar.system.removeStatusItem(item) }

    private func render() {
        let (color, status): (NSColor, String) = switch session.state {
        case .stopped: (.systemGray, "Stopped")
        case .starting: (.systemYellow, "Starting…")
        case .running: (.systemGreen, "Running")
        case .failed(let reason): (.systemGray, reason)
        }
        item.button!.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in   // 16 pt square, 10 pt dot: menu-bar glyph scale
            color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3)).fill(); return true
        }
        let menu = item.menu!
        menu.removeAllItems()
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        menu.addItem(Row("Start transcription") { [session] in session.start() })
        menu.addItem(Row("Stop transcription") { [session] in Task { await session.stop() } })
        menu.addItem(.separator())
        menu.addItem(toggleRow("Microphone", .mic))
        let host = NSMenuItem(title: "Attach to Apps", action: nil, keyEquivalent: "")
        host.submenu = appsMenu()
        menu.addItem(host)
        settings.forEach(menu.addItem)
        for reason in session.failures.values.sorted() + [session.deleteError].compactMap({ $0 }) { menu.addItem(withTitle: reason, action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(Row("Delete old transcriptions") { [session] in session.deleteOld() })
        menu.addItem(.separator())
        menu.addItem(Row("Quit") { [session] in Task { await session.quit() } })
    }

    private func appsMenu() -> NSMenu {
        let m = NSMenu()
        for (i, group) in WindowCatalog.groups(catalog.windows).enumerated() {
            if i > 0 { m.addItem(.separator()) }
            for w in group { m.addItem(toggleRow(w.title, .app(bundleId: w.bundleId, tag: String(w.title.prefix(5))))) }
        }
        for case .app(let bundleId, let tag) in session.attached where !catalog.windows.contains(where: { $0.bundleId == bundleId }) {
            m.addItem(toggleRow(tag, .app(bundleId: bundleId, tag: tag)))   // no window left: still detachable
        }
        if let e = catalog.error { m.addItem(withTitle: e, action: nil, keyEquivalent: "") }
        if m.items.isEmpty { m.addItem(withTitle: "No windows", action: nil, keyEquivalent: "") }
        return m
    }

    private func toggleRow(_ title: String, _ target: Target) -> Row {
        Row(title, on: session.attached.contains { $0.id == target.id }) { [session] in Task { await session.toggle(target) } }
    }
}
```
## `Sources/TranscribeEverything/main.swift` (edit the `case nil:` arm)
Replace `let bar = MenuBar(session: session)` by
```swift
let catalog = WindowCatalog(permissions: session.permissions)
let bar = MenuBar(session: session, catalog: catalog, settings: [])
```
and add `catalog` to the `withExtendedLifetime` tuple. S11 and S14 fill `settings`.

## `Sources/TEUI/Verify.swift` (edit)
`enum Step` gains `case windows`; `init(from:)` gains `case "windows": self = .windows`; `run` gains
```swift
case .windows: return ["op": "windows", "windows": try JSONSerialization.jsonObject(with: JSONEncoder().encode(try await WindowCatalog.system()))]
```
The compiler flags a missed switch. Scenario: `{"op":"windows"}`.

## `Tests/TECoreTests/AppRig.swift` (edit `Rig`, additive)
- `Rig.init` gains `every: TimeInterval = 3600` (timer effectively off; tests call `await catalog.refresh()`) and `settings: [NSMenuItem] = []`, builds `windows = FakeWindows()`, `catalog = WindowCatalog(permissions: permissions, every: every) { [windows] in windows.fetches += 1; return windows.list }`, and replaces `bar = MenuBar(session: session)` by `MenuBar(session: session, catalog: catalog, settings: settings)`.
- `Rig` exposes `catalog`, `windows`, and `func submenu() -> NSMenu { bar.item.menu!.item(withTitle: "Attach to Apps")!.submenu! }`. The submenu is rebuilt on every change: call `submenu()` again after each click.
- Add `@MainActor final class FakeWindows { var list: [WindowCatalog.Window] = []; var fetches = 0 }`.
- Every S9 test still passes unchanged: an empty window list adds only rows.

## `Tests/TECoreTests/StoreTests.swift` (add)
`testDeleteOldKeepsExactlyTheCurrentFileAndForeignFiles`: root with `TranscriptStore(paths:, start: Date(timeIntervalSince1970: 1))`, `…2`, and `current` (`…3`), plus `notes.txt` in the same directory. `deleteOld(in:, except: current.file)` ⇒ directory listing is exactly `{current's name, notes.txt}`; the store still appends a line afterwards. `except: nil` ⇒ exactly `{notes.txt}`. A root with no `transcripts` directory ⇒ no throw. Mutants: delete everything ⇒ red; ignore `current` ⇒ red; drop the `jsonl` filter ⇒ `notes.txt` gone ⇒ red.

## `Tests/TECoreTests/AttachTests.swift` (class `AttachTests`, category Attach)
`@MainActor`, reusing `Rig`. Windows: `notes1 = Window("com.apple.Notes", "Notes", "Meeting")`, `notes2 = …"Todo"`, `safari = Window("com.apple.Safari", "Safari", "News")`. `notesTarget = .app(bundleId: "com.apple.Notes", tag: "Meeti")`. Support (this file):
```swift
func limitFileSize(to bytes: Int) -> rlimit    // signal(SIGXFSZ, SIG_IGN); getrlimit(RLIMIT_FSIZE); setrlimit(soft = bytes, hard unchanged); returns the old limits
func restoreFileSize(_ old: rlimit)
func spin(_ mode: RunLoop.Mode, seconds: Double, until: () -> Bool) -> Bool   // RunLoop.current.run(mode:, before: now + 0.05) until true or the deadline
```
Every real-engine test sets `executionTimeAllowance = 90`.

1. **`testGroupsDedupAndOrderByAppThenBundleThenTitle`** (pure). Input: Safari/`com.apple.Safari` "News" ×2, "Apple"; TextEdit/`com.apple.TextEdit` "b.txt", "a.txt"; app "Safari" with `org.x.Safari2` "Zed". Expected, literal: `[[Safari "Apple", Safari "News"], [Safari2 "Zed"], [TextEdit "a.txt", TextEdit "b.txt"]]`. Mutants: drop the `Set` ⇒ "News" twice ⇒ red; sort groups by title ⇒ red; group by app name ⇒ the two Safaris merge ⇒ red.
2. **`testClickingARowChecksAllOfThatAppsRowsAndASecondClickDetaches`.** Rig running; `windows.list = [notes1, notes2, safari]`; `await catalog.refresh()`. Submenu titles in order `Meeting, Todo, (separator), News`. Click "Meeting"; eventually `attached == [notesTarget]`; rows: Meeting `.on`, Todo `.on`, News `.off`; eventually `tail(notesTarget.id)` whose `tag == "Meeti"`. Click "Todo" ⇒ eventually `attached.isEmpty`, all three `.off`. Mutants: check only the clicked row ⇒ red; a click on a checked row attaches again ⇒ red; tag untruncated ⇒ red.
3. **`testAnAttachedAppWithNoWindowsKeepsARowToDetach`.** As 2 until attached; `windows.list = [safari]`; refresh. The submenu still has a row `"Meeti"` `.on`; click it ⇒ eventually `attached.isEmpty` and the row is gone. Mutant: render only catalog windows ⇒ red.
4. **`testCatalogUpdatesWhileTheMenuIsOpenOnlyOnChangeAndOnlyWhileScreenRecordingIsGranted`** — synchronous `@MainActor` (item 3). `Rig(every: 0.1)`, no start. `windows.list = [notes1]`; `spin(.default, 3) { submenu has "Meeting" }`. `windows.list = [notes1, safari]`; `spin(.eventTracking, 3) { submenu has "News" }`. Stable list: `m = submenu()`; `spin(.default, 0.5) { false }`; `m === submenu()` (no rebuild without a change). `have.remove(.screenRecording)`; `spin(.default, 1) { submenu has a disabled row "Screen Recording not granted" }`; `n = windows.fetches`; `spin(.default, 0.5) { false }`; `fetches == n`; `have.insert(.screenRecording)`; `spin(.default, 3) { fetches > n }`. Mutants: `forMode: .default` ⇒ the `.eventTracking` spin never shows "News" ⇒ red; drop the equality guard in `refresh` ⇒ `m !== submenu()` ⇒ red; delete the permission guard ⇒ `fetches` grows ⇒ red.
5. **`testAFailedSourcesReasonIsADisabledMenuRowUntilItIsAttachedAgain`.** `c.provide[notesTarget.id] = FailingSource(base: FileSource(url: Fixtures.conversationWav, id: notesTarget.id, tag: "Meeti", clock: ContinuousClock()), failAt: 49_152)`; windows `[notes1]`; running rig; click "Meeting"; eventually `attached.isEmpty`. The top-level menu has a row with `action == nil` titled exactly `"Meeti: boom"`. Provide a fresh paced `FileSource`; click "Meeting" again ⇒ the reason row is gone at once. Mutant: `toggle` does not clear the reason ⇒ red.
6. **`testAFailingFinalFlushStillClearsTheTailAndReportsTheFailure`** (engine-level, `makeEngine`). `src` = `FileSource(url: truncated(Fixtures.conversationWav, frames: 48_000, in: dir), id: "a", tag: "A", clock: ContinuousClock())` (ends at 3.0 s with turn 0's segment open). Attach; eventually the tail exists; `old = limitFileSize(to: 0)` (the file is empty, so the final commit's write fails); `ends = await awaitEnds(engine, 1)`; `restoreFileSize(old)` (also in `defer`). Assert `ends[0].error != nil` (its text goes to the results log), `snapshot().tails.isEmpty`, `lines.isEmpty`, file size `== 0`. Mutant: in `TranscriptStore.commit` move `slots[i].tail = nil` below the write loop ⇒ the tail stays ⇒ red.
7. **`testDeleteOldTranscriptionsKeepsOnlyTheCurrentFileAndShowsAFailure`.** Before start: two stores at `start: 1`, `2` plus `notes.txt` in `root/transcripts`. Start, eventually running; click "Delete old transcriptions" ⇒ `files() == [current]` and `notes.txt` exists. Stop, eventually `.stopped`; click Delete ⇒ `files() == []`. `chmod 0o000` on `root/transcripts` (restored in `defer` and teardown); click Delete ⇒ a disabled top-level row whose title starts `"Delete old transcriptions:"`. Restore `0o755`, click Delete ⇒ the row is gone. Mutants: the action swallows the error ⇒ red; deletes with `except: nil` while running ⇒ red.
8. **`testSettingsItemsSitRightAfterTheAttachRowAndSurviveRebuilds`.** `Rig(settings: [NSMenuItem(title: "Probe item", action: nil, keyEquivalent: "")])`. The item follows "Attach to Apps" at once, and still does after a state change (`start()`, eventually running). Mutant: `render` adds it before the Attach row ⇒ red.
9. **`testTextEditWindowAppearsAndLeavesInTheRealWindowList`** (real SCK under the app identity). `TextEdit` helper (this file): `open(file)` refuses if `pgrep -x TextEdit` is non-empty (the test quits it; it may be Minh's), then `open -g -a TextEdit <file>`; `windowCount()` = osascript `tell application "TextEdit" to count windows`; `closeAll()` = `close every document`; teardown quits it; all through `AppHarness.sh`. Steps: `uuid`; file `te-s10-<uuid>.txt` in a temp dir; `TextEdit.open`; `eventually("window listed")` { a `windows` run (`AppHarness.run(root: temporaryRoot(self), steps: [["op": "windows"]])`) lists a window with `bundleId == "com.apple.TextEdit"` and a title containing `uuid` }; `closeAll()`; `eventually("window gone")` { a `windows` run lists none }. Mutants: layer filter `== 5` ⇒ never listed ⇒ red.

Each mutant: one edit, the single named test red, revert, green.

## Steps to attain the human-verifiable result
1. Order: `SourcePipeline` tail + `deleteOld` + `StoreTests` addition (`./test.sh Store`, `./test.sh Pipeline`, `./test.sh Live` green) ⇒ `WindowCatalog.swift` ⇒ `AppController` members, `MenuBar` rewrite, `main.swift` ⇒ `swift build` ⇒ `AppRig` edit (`./test.sh Lifecycle` still green) ⇒ `AttachTests` 1–8 ⇒ `Verify.swift` + test 9 under pacemaker ⇒ mutants ⇒ full `./test.sh` ⇒ fresh adversarial review.
2. `./build.sh`, `open ~/Applications/TranscribeEverything.app`, open a few real windows (Safari, Notes, TextEdit).
3. Minh opens the menu, hovers Attach to Apps and keeps it open for 20 s. Meanwhile the agent runs the script `conversation-contexts/transcribe-everything/scripts/menu-shot.swift` (not in the repo) with `rac exec bash -c 'sleep 8; for id in $(swift menu-shot.swift); do screencapture -x -o -l$id /tmp/menu-$id.png; done'`. The script lists `CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)` entries whose `kCGWindowOwnerName` is `TranscribeEverything` and `kCGWindowLayer > 0`, printing each `kCGWindowNumber`. Window-scoped (`-l`), so nothing else on screen is captured.
4. Read the PNGs: app rows with real window titles, grouped by app, separators between apps. Click one row, reopen: all that app's rows are checked. Record the result.
