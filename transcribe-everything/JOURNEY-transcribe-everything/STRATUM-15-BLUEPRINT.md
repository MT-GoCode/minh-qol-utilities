# Stratum 15 Blueprint — Install (End of transcribe-everything Period)

Builds on S1–S14. Ground truth read: `build.sh`, `setup.sh`, `test.sh`, `AppHarness.swift` and `AppTests.swift` (S6, in the repo), `Verify.swift` (`Step` grammar), S7's `eventually` and `Launch` (both go through `AppHarness.run`), S8's `AppHarness.requireUnlocked`, S9's `SystemPermissions`/`Permission`, wtalk's `install/{install.sh,uninstall.sh,com.minh.wtalk.agent.plist}`.

This stratum also holds the **final text of the composition root** (`main.swift`, below): S9–S14 each edited named lines of it, and test 8 proves the installed app built every part.

# Uncertainties squashed

1. **launchd, probed with a throwaway agent** (label `com.minh.te-probe`, `KeepAlive: {SuccessfulExit: false}`): `bootout` then `bootstrap` three times back to back raises no error; `bootout` of a job that is not loaded prints `Boot-out failed: 3: No such process` and exits non-zero ⇒ the scripts need `|| true` there and only there. `kill -9` restarts the job after **10 s** by default and **1 s** with `ThrottleInterval 2` (wtalk's value); a job that exits 0 ran once and stayed `not running`, `last exit code = 0` ⇒ a crash restarts and a clean Quit stays quit. After `bootout`, `launchctl print gui/<uid>/<label>` exits **113**; while loaded it exits 0 and prints `\tpid = N` (one tab) when running.
2. **The scripts were run** under a temporary `HOME` with a shim `launchctl` and stub `setup.sh`/`build.sh`: calls were `setup, build, bootout gui/501/<label>, bootstrap gui/501 <plist>` (the shim made `bootout` exit 3; install still succeeded); `uninstall.sh` kept `~/.transcribe-everything` and a sibling `~/.other`; `--purge` removed only the data root; `--purg` exited 2 with the usage line.
3. **wtalk's structure, minus sudo**: flat `install.sh`/`uninstall.sh` at the repo root, bundle in `~/Applications`, agent in `~/Library/LaunchAgents`, wtalk's plist keys and `--purge`; three constants shared through a sourced `app/env.sh`. No data seeding (the app writes its config on first run, S14); the install only creates the data root because launchd opens the log file there before the app runs.
4. **Isolation.** Every path comes from `$HOME`, so a temporary `HOME` isolates the files. The launchd domain `gui/<uid>` is global: script tests put a recording `launchctl` first on `PATH`; real `launchctl` runs only in harness tests (throwaway label) and the real tests. Stub `setup.sh`/`build.sh` stand for scripts already tested (S1, S6); `install.sh` does `cd "$(dirname "$0")"` and calls `./setup.sh`, `./build.sh`, so copying the scripts beside stubs needs no seam in product code.
5. **Build lock.** `swift test` holds `.build/.lock` for the whole run (S1 item 7), so `setup.sh` gets `--scratch-path .build-app`, the scratch `build.sh` uses.
6. **One launch path.** All real launches go through `AppHarness.run` (S7's `Launch` calls it), so the bootout/restore wraps one call and follows each launch: a crashed `swift test` leaves the agent down for seconds, not for good. A restarted agent loads models from cache (0.11 s, DECISIONS) with nothing attached. Each agent start writes one empty transcript file in the real data root (every start makes a store); Delete old transcriptions clears them.
7. **Permission preflight has one owner**: `SystemPermissions` (S9), called through `MainActor.run` by the `permissions` op. The `verify` instance is launched by `open`, which makes the app the permission holder (S6); grants persist across delete-and-recreate and re-sign (DECISIONS). Direct exec shows as ppid 1 (DECISIONS, verified).
8. **The window list proves the wiring.** `CGWindowListCopyWindowInfo` reports owner pid, layer and bounds without any permission (only window names need Screen Recording). The status item is layer 25 (`NSStatusWindowLevel`); the overlay panel is `.floating`, layer 3, width 760. Settled at build: both appear in the listing (the raw listing goes to the results folder). A started engine is proven by a new transcript file.
9. **Accepted and deferred.** A crash restart comes back green with nothing attached (DECISIONS). `app.log` has no rotation (a few lines per start; OTHER.md). "Quit stays quit" is in the human gate: no automated check can press Quit without Automation permission.

# Blueprint

Files: `app/env.sh`, `install.sh`, `uninstall.sh`, `README.md`, `build.sh` (edit), `setup.sh` (edit), `Sources/TranscribeEverything/main.swift` (final text), `Sources/TEUI/Verify.swift` (edit), `Tests/TECoreTests/{AppHarness,InstallTests}.swift`. `chmod +x install.sh uninstall.sh`.

## `Sources/TranscribeEverything/main.swift` (final; the `case nil:` arm is the one composition root)
```swift
case nil:
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let paths = Paths()
    let config = try await ConfigStore.open(file: paths.config)
    var session: Session!   // the overlay reads the session through closures and the session starts the overlay: neither can be built first
    let overlay = Overlay(config: config, attached: { Set(session.attached.map(\.id)) }, failures: { session.failures.values.sorted() })
    session = Session(paths: paths, config: config, onStart: { overlay.bind($0) })
    session.observe { overlay.refresh() }
    let catalog = WindowCatalog(permissions: session.permissions)
    let fontSize = await FontSizeItem(config: config)
    let bar = MenuBar(session: session, catalog: catalog, settings: [overlay.hideShowItem, fontSize.item])
    session.start()
    withExtendedLifetime((session!, overlay, catalog, fontSize, bar)) { app.run() }
```
The `prefetch`, `verify` and usage arms are unchanged. Every name is the one its stratum defined; the file is the only place a `Session`, `Overlay`, `WindowCatalog`, `FontSizeItem` and `MenuBar` meet. Review check (not a test): no other file constructs `Session`, `Overlay`, `MenuBar`, `WindowCatalog` or `FontSizeItem` outside tests and `Verify`'s `overlay` op.

## `app/env.sh` (new)
```bash
# Shared by build.sh, install.sh and uninstall.sh. DATA mirrors Paths.swift's default root.
LABEL=com.minh.transcribe-everything
APP="$HOME/Applications/TranscribeEverything.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DATA="$HOME/.transcribe-everything"
DOMAIN="gui/$(id -u)"
```

## `build.sh` and `setup.sh` (one-line edits)
- `build.sh`: delete the line `APP="$HOME/Applications/TranscribeEverything.app"` and add `. app/env.sh` directly after `cd "$(dirname "$0")"`. `STAGE=…` stays.
- `setup.sh`: `swift run -c release --scratch-path .build-app TranscribeEverything prefetch`.

## `install.sh` (new)
```bash
#!/bin/bash
# Installs the app and its LaunchAgent for this user. No sudo.
set -euo pipefail
cd "$(dirname "$0")"
. app/env.sh

./setup.sh
./build.sh
mkdir -p "$DATA" "$(dirname "$PLIST")"
# Exec the binary directly: the permission grants follow the signed app, and launchd restarts it only after a crash
# (a clean Quit exits 0 and stays quit). ThrottleInterval 2: restart ~1 s after a kill; the default waits 10 s.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/TranscribeEverything</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>2</integer>
  <key>StandardOutPath</key><string>$DATA/app.log</string>
  <key>StandardErrorPath</key><string>$DATA/app.log</string>
</dict></plist>
PLIST
plutil -lint "$PLIST" >/dev/null
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true  # not loaded on a first install
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed $APP; agent $LABEL loaded"
```
Order matters: `build.sh` replaces the bundle, then `bootout` stops the old process, then `bootstrap` starts the new binary. Running it twice leaves one copy and one plist.

## `uninstall.sh` (new)
```bash
#!/bin/bash
# Removes the LaunchAgent and the app. Keeps ~/.transcribe-everything (transcripts, config) unless --purge.
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in "" | --purge) ;; *) echo "usage: uninstall.sh [--purge]" >&2; exit 2 ;; esac
. app/env.sh

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true  # not loaded when never installed
rm -rf "$APP"
rm -f "$PLIST"
if [ "${1:-}" = --purge ]; then rm -rf "$DATA"; fi
echo "uninstalled"
```
It does not stop a copy someone started by hand (`open`); `bootout` stops the agent's copy.

## `README.md` (new; this text, nothing more)
```markdown
# transcribe-everything

Live captions of any app and the microphone, on this Mac. Parakeet Ultra runs on the Neural Engine; nothing leaves the machine.
A menu-bar app: the icon is yellow while the engine starts and green when it is ready.

## Install
    ./install.sh        # models, signed app in ~/Applications, LaunchAgent that starts it at login. No sudo.
Needs a "Developer ID Application" certificate in the login keychain (a changed signature resets permission grants).
Grant Microphone and Screen Recording when asked; the menu names what is missing, and a grant applies after relaunch.

## Use
- Menu ▸ Attach to Apps ▸ a window (its whole app is captured), or Microphone. Each source is its own stream.
- Captions appear over your screen; the bar moves them (⠿), expands to the last minute (⌃), hides them (eye). Text can be selected and copied.
- Transcripts: `~/.transcribe-everything/transcripts/<start time>.jsonl`, one JSON line per caption line.
- Settings: `~/.transcribe-everything/config.json`, applied as soon as you save. The font size is also a slider in the menu.

## Uninstall
    ./uninstall.sh            # keeps ~/.transcribe-everything
    ./uninstall.sh --purge    # also deletes it

## Tests
    ./test-setup.sh           # once: fixtures and the reference transcripts
    ./test.sh [filter]        # the whole suite; results in test-results/<time>/
Some tests launch the installed app, mute the output briefly, and restart the LaunchAgent.
```

## `Sources/TEUI/Verify.swift` (edit: one new case in `Step`, routed in the existing places)
`enum Step`: add `case permissions`; in `init(from:)` add `case "permissions": self = .permissions`; in `run`:
```swift
case .permissions:
    let granted = await MainActor.run { let p = SystemPermissions(); return Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0.rawValue, p.granted($0)) }) }
    return ["op": "permissions", "granted": granted]   // keys "Microphone", "Screen Recording"
```
The compiler flags any switch that misses the case.

## `Tests/TECoreTests/AppHarness.swift` (edit)
```swift
enum HarnessError: Error { …existing…, agent(String) }   // add this case

static let label = "com.minh.transcribe-everything"
static let agentPlist = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")

/// Stops the LaunchAgent for `body` if it is loaded and starts it again afterwards, whether or not `body` threw.
/// A second copy of the app cannot run beside the agent's: both would hold the one set of permissions and the same data root.
static func withAgentStopped<T>(label: String, plist: URL, _ body: () throws -> T) throws -> T {
    let domain = "gui/\(getuid())"
    guard try sh("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0 else { return try body() }
    let out = try sh("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
    guard out.status == 0 else { throw HarnessError.agent("bootout \(label): \(out.out)") }
    let result = Result { try body() }
    let back = try sh("/bin/launchctl", ["bootstrap", domain, plist.path])
    guard back.status == 0 else { throw HarnessError.agent("bootstrap \(label) failed, the agent is down: \(back.out)") }
    return try result.get()
}
```
In `run(root:steps:)`: wrap the `open -W -n …` call and the report read in `try withAgentStopped(label: label, plist: agentPlist) { … }`. Nothing else in `run` changes. A body failure is rethrown after the restore; a restore failure is thrown instead because the agent being down matters more.

## `Tests/TECoreTests/InstallTests.swift` (class `InstallTests`, category Install)
Helpers (test-local):
```swift
private func launchctlLoaded(_ label: String) throws -> Bool   // sh launchctl print gui/<uid>/<label>, status == 0
private func pid(_ label: String) throws -> Int?               // regex "\n\tpid = (\d+)\n" on the print output
private func throwaway(_ test: XCTestCase) throws -> (label: String, plist: URL)
  // label "com.minh.transcribe-everything.test-" + 8 hex chars of a UUID; plist in temporaryRoot with
  // Label, ProgramArguments ["/bin/sleep", "1000"], RunAtLoad true; teardown: bootout gui/<uid>/<label>, ignoring failure
private struct Sandbox {
    // init(test): home, repo, shim under temporaryRoot. Copies AppHarness.repo/{install.sh,uninstall.sh,app/env.sh} into repo/ (same relative layout).
    // repo/setup.sh = `#!/bin/bash\necho setup >> "$HOME/calls"`.
    // repo/build.sh = `#!/bin/bash\necho build >> "$HOME/calls"\n. "$(dirname "$0")/app/env.sh"\nmkdir -p "$APP/Contents/MacOS"\necho bin > "$APP/Contents/MacOS/TranscribeEverything"`.
    // shim/launchctl = `#!/bin/sh\necho "launchctl $*" >> "$HOME/calls"\n[ "$1" = bootout ] && exit 3\nexit 0`.
    // All chmod 755.
    func run(_ script: String, _ args: [String] = []) throws -> (status: Int32, out: String)
      // AppHarness.sh("/bin/bash", [repo/script] + args, env: ["HOME": home.path, "PATH": shim.path + ":" + ProcessInfo.processInfo.environment["PATH"]!])
    var calls: [String]   // lines of home/calls, [] if absent
}
```
Expected strings are built from `getuid()`, `home.path` and the literal label `com.minh.transcribe-everything`, never from the scripts.

**Script tests (no models, no permissions, real files under a temporary HOME):**
1. **`testInstallTwiceSucceedsEvenThoughBootoutFindsNothingLoaded`.** `r = run("install.sh")`: status 0 (the shim makes `bootout` fail like a not-loaded job, so a script without `|| true` dies). `<home>/.transcribe-everything` is a directory; the plist exists and `plutil -lint` on it exits 0 (the real tool). Run again: status 0, plist bytes identical, `<home>/Applications` has exactly one entry. Mutant: delete `|| true` ⇒ status 3 ⇒ red. (What the plist makes launchd do is proven by tests 6 and 7, not by reading its text.)
2. **`testUninstallKeepsDataAndPurgeRemovesOnlyTheDataRoot`.** `run("install.sh")`. Create `<home>/.transcribe-everything/{config.json, transcripts/a.jsonl}`, sentinels `<home>/.transcribe-everything-notes/k`, `<home>/.other/k`, `<home>/Documents/k`, `<home>/Applications/Other.app/Contents/k`. `run("uninstall.sh")`: status 0; the app dir and the plist are gone; `calls.last == "launchctl bootout gui/<uid>/com.minh.transcribe-everything"`; `config.json`, `transcripts/a.jsonl` and every sentinel exist. `run("uninstall.sh")` again: status 0. `run("install.sh")` then `run("uninstall.sh", ["--purge"])`: status 0; `<home>/.transcribe-everything` does not exist; every sentinel (including the one sharing the data root's name as a prefix) and `Other.app` exist; the app and plist are gone. Mutants: plain uninstall also removes the data root; `--purge` as `rm -rf "$HOME"/.transcribe-everything*` ⇒ prefix sentinel red; `rm -rf "$HOME/Applications"` ⇒ `Other.app` red; no `bootout` ⇒ `calls.last` red.
3. **`testUninstallRejectsAnUnknownArgumentAndChangesNothing`.** After install: `run("uninstall.sh", ["--purg"])` ⇒ status 2, `out` contains `usage`, the app and plist exist, `calls` unchanged. Mutant: ignore the argument ⇒ status 0 ⇒ red.

**Harness tests (real `launchctl`, throwaway label, nothing of Minh's touched):**
4. **`testHarnessStopsALoadedAgentForTheBodyAndStartsItAgain`.** `a = throwaway`; `bootstrap` it; `pid(a.label)` non-nil. `withAgentStopped(label:plist:) { XCTAssertFalse(launchctlLoaded) }`. Afterwards loaded, with a pid. Mutants: no `bootout` ⇒ inside loaded ⇒ red; no `bootstrap` ⇒ afterwards not loaded ⇒ red.
5. **`testHarnessStartsTheAgentAgainWhenTheBodyThrows`.** Loaded throwaway; body throws `Boom`; `XCTAssertThrowsError` and it is the `Boom`; afterwards loaded. Mutant: restore only on success ⇒ red.

**Real tests (the installed app, the real agent; `executionTimeAllowance` 1200 s; run through pacemaker):**
```swift
private static let installed = Result<[String: Int], Error> {   // the transcripts listing (name → byte size) from before the reinstall
    try AppHarness.ready.get()
    let before = listing(Paths().transcripts)
    for script in ["uninstall", "install"] {
        let log = resultsDir().appending(path: "\(script).log")
        let r = try AppHarness.sh("/bin/bash", [AppHarness.repo.appending(path: "\(script).sh").path], log: log)
        guard r.status == 0 else { throw HarnessError.buildFailed(r.status, log: log.path) }
    }
    return before
}
```
6. **`testReinstallRunsTheAppDirectlyUnderTheAgentWithPermissionsAndTranscriptsKept`.** `before = try installed.get()`. `eventually("agent running")`: `pid(AppHarness.label) != nil`. With `p`: `ps -o command= -p p` trimmed equals `AppHarness.executable(AppHarness.app).path`; `ps -o ppid= -p p` trimmed equals `"1"`. Every file of `before` still exists in `listing(Paths().transcripts)` with the same size, and the listing has more files than `before` (the agent's start made one: the engine started under the agent). `report = try AppHarness.run(root: temporaryRoot, steps: [["op": "permissions"]])`; `results[0]["granted"]` has `"Microphone"` and `"Screen Recording"` both `true`; on false the failure message says which permission to grant in System Settings and that the grant applies after relaunch. After `run`, `eventually` the agent is running again (the harness restored it). Mutants: `install.sh` without `bootstrap` ⇒ no pid ⇒ red; plist `ProgramArguments` through `open` ⇒ command mismatch / ppid not 1 ⇒ red; `uninstall.sh` removing the data root ⇒ listing red (when data exists).
7. **`testACrashedAppIsRestartedByTheAgent`.** `_ = try installed.get()`; `eventually` pid `p1`; `Foundation.kill(pid_t(p1), SIGKILL)`; `eventually("restarted")`: `pid(label)` non-nil and `!= p1`; its `ppid` is `1`. Measured restart: 1 s with `ThrottleInterval 2`, 10 s without (item 1); `eventually`'s 15 s deadline covers both, so the mutant is the plist without `KeepAlive` ⇒ never restarts ⇒ red (and `SuccessfulExit: true` ⇒ red).
8. **`testTheInstalledAppBuiltItsMenuBarItemAndItsOverlay`** (`requireUnlocked()` first). `_ = try installed.get()`; `eventually` pid `p`. `eventually("windows")`: `CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)` entries with `kCGWindowOwnerPID == p` include one with `kCGWindowLayer == 25` (status item) and one with `kCGWindowLayer == 3` and `kCGWindowBounds["Width"] == 760` (overlay panel); the listing goes to the results folder. Mutants: delete the `MenuBar(...)` line of `main.swift` ⇒ no layer 25 ⇒ red; delete the `Overlay(...)` line ⇒ no 760-wide floating window ⇒ red. (That `onStart` binds the overlay and `settings` reach the menu is proven by S9–S13's rigs, which build the same pieces, and by the human gate below; this test proves only that the real root builds them.)

## Steps to attain the human-verifiable result
1. `./test.sh Install` under pacemaker (test 6 may build in `.build-app`: minutes the first time). Read `test-results/<time>/{uninstall,install}.log`.
2. Mutants of tests 1–3, 7 and 8, one at a time (edit, run, red, revert, green).
3. `./test.sh` whole suite, once, under pacemaker (parent step), then the whole-codebase review (parent step, End of Period).
4. **Human gate (Minh):**
   1. Log out and in (or restart). The icon appears yellow, then green, with no click. `launchctl print gui/$(id -u)/com.minh.transcribe-everything | grep -E 'pid|state'` shows it running.
   2. Join a real Zoom meeting with at least two remote speakers. Menu ▸ Attach to Apps ▸ the Zoom window. Captions appear; each remote voice gets its own `[Speaker N]`; `tail -f ~/.transcribe-everything/transcripts/*.jsonl` shows the same lines with the same labels. The font slider and Hide/Show are in the menu and work.
   3. Menu ▸ Quit. The icon disappears and stays gone for 10 s; `launchctl print …` shows `last exit code = 0` and no pid. `./install.sh` brings it back.
   4. `./uninstall.sh` then `./install.sh`: the app returns without asking for permissions again.

# Build findings (supersede the sections above)
- The composition root in `main.swift` builds its parts inside a `Task`, and `app.run()` runs from the entry point: the blueprint's text awaited first, which kept the engine from ever starting.
- Test 8 finds only the overlay: `MenuBarAgent` hosts status items on this macOS, so a status item has no window under the app's pid. The human gate sees the dot.
- `install.sh` waits for the old job to be gone before bootstrapping: an immediate bootstrap failed with an I/O error on a real reinstall.
- New `session` verify op and test: a real catalog window, attached through the real Session and source lookup, gives captions. The rigs inject a fake source, and the capture op bypasses Session, so nothing else walked this path (End-of-Period review).
