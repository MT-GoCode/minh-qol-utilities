# Stratum 6 Blueprint — The app identity: build, sign, install, verify

# Uncertainties squashed

1. **Signing identity.** `security find-identity -p codesigning -v` on this Mac lists exactly one identity: `Developer ID Application: Minh Trinh (BULCQM9J2V)`. The installed probe app already shows `flags=0x10000(runtime)`, `Authority=Developer ID Application: Minh Trinh (BULCQM9J2V)` (`codesign -dvv`) and the entitlement `com.apple.security.device.audio-input` (`codesign -d --entitlements -`). `build.sh` does not call `../signing-ladder.sh`: the ladder's step 3 creates a keychain certificate as a side effect and steps 3–4 are the fallbacks S6 forbids. It runs the ladder's step-2 `awk` itself, once, and exits when empty. No fallback path exists.
2. **Hash check needs a signed staging bundle.** Signing rewrites the Mach-O, so the SwiftPM output never equals the installed binary. `build.sh` signs in `.build-app/TranscribeEverything.app` and `ditto`s that bundle to `~/Applications`. The harness compares the installed executable's SHA-256 to the staged one. `ditto` copies bytes unchanged. The check fails if the install step did not happen or something else replaced the copy.
3. **Build lock.** STRATUM-1 uncertainty 7 measured it: `swift test` holds `.build/.lock`. `build.sh` uses `--scratch-path .build-app` (already in `.gitignore`), so `AppHarness` can build mid-test. The first build compiles FluidAudio from scratch in `.build-app` and takes minutes. Run the S6 gate through pacemaker.
4. **Screen lock key (probed).** `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` returned `1` on this Mac while its screen was locked. The unlocked form could not be observed now (the session was locked), so the check is `(dict?["CGSSessionScreenIsLocked"] as? Bool) == true`: absent or `0` reads as unlocked. The first S6 run on an unlocked screen confirms it passes. The key is only read, so no other form can turn a locked screen into a pass.
5. **Mute state (probed read).** `osascript -e 'output muted of (get volume settings)'` prints `false`/`true` over a plain ssh session. Setting uses `set volume output muted true|false`, the same command family. No GUI permission is needed for CoreAudio volume.
6. **LaunchAgent state (probed).** `launchctl print gui/501/com.minh.transcribe-everything` exits non-zero ("Could not find service") when the agent is absent. Exit 0 means loaded. No agent exists until S15, so S6 exercises the not-loaded branch only. The loaded branch is two `launchctl` calls with the documented forms `bootout gui/<uid>/<label>` and `bootstrap gui/<uid> <plist>`, first run for real in S15. `~/Library/LaunchAgents/<label>.plist` is the path S15 installs to.
7. **`beginActivity(.latencyCritical)` is not observable.** Probed: with the activity held, `pmset -g assertions` shows no new assertion (`PreventUserIdleSystemSleep 0`, `PreventSystemSleep 0`), and `ProcessInfo` has no query for held activities. No automated test can see it, so none is written and no mutant is claimed. DECISIONS measured the app under a LaunchAgent with the activity held (12 s decode 69–72 ms). S15 repeats a decode run under the agent.
8. **Launch via `open -W -n --args`** is the probe's proven recipe (`spike/probe.sh`): it makes the app, not the terminal, the TCC-responsible process. `open -W` returns when the app exits and does **not** forward its exit status, so success is decided by the report file, which the harness deletes first. `--stdout/--stderr` capture the app's output into the results folder.
9. **A top-level `await` keeps `main.swift` alive**, so `verify` needs no `NSApplication` run loop and exits with `exit(0)`. A normal launch calls `NSApplication.shared.run()` after setting `.accessory`, as the probe did. `LSUIElement` is in the plist.
10. **FluidAudio calls.** None are new. `Transcriber.load()`, `VadManager()`, `Embedder.load()` (S1/S2/S3, in the repo). `AudioConverter` is reached through `FileSource`. `AppController` and `Verify` import only TECore.
11. **Swift language mode.** `Package.swift` sets `swiftLanguageModes: [.v5]`, so an `actor` stored property of type `NSObjectProtocol` (the activity token) and its use in `deinit` compile without Sendable errors. Checked at build; if it fails, stop and report.
12. **Test timing.** `swift test` runs with `--parallel --num-workers 1`. The harness's `static let` build runs once per test process. If a second process ever exists, `build.sh` re-runs: it is idempotent (incremental, reinstalls the same bytes).
13. **Turn lengths** (`fixtures/conversation.json`): 3.0, 6.6, 4.5, **11.9**, 2.7, 4.5, 10.7, 3.1, 8.3, 15.4, 4.6, 14.8 s. Turn 3 (11.9 s) is the "12 s" latency clip. The 15.4 s and 14.8 s turns are under 480,000 samples (S1).
14. **Latency bound origin.** STRATA: 12 s decode ≤ 2× the probe's measured 72 ms = 144 ms. Probe method (`spike` Probe `decode`): 9 decodes, the first dropped as warm-up, the median of 8. The test repeats that method. S4's soak showed decode medians 50–58 ms with occasional 300 ms maxima, hence the median.
15. **OTHER.md resolutions.** (a) "S6: `AppHarness` mutes output and launches apps; add a warning or idle wait" — resolved: `AppHarness.muted` prints a warning to stderr naming the mute and the restore, and restores the previous mute state, not always "unmuted". An idle wait was rejected: no cheap reliable "is a call in progress" signal exists. S6's own tests launch only; one test runs `muted` for a moment. (b) "S1: `build.sh` may need its own `--scratch-path`" — resolved by uncertainty 3. Parent: move both items out of OTHER.md.
16. **Spike deletion.** `spike/FIXTURE-SOURCES.md` has four URLs; all four already appear verbatim in `fixtures.py` (LibriSpeech `:42`, AMI audio `:101`, AMI labels `:105`, VoxConverse `:116`). The only other files that cite `spike/` are DECISIONS.md line 32 ("Spike code: `spike/`…"), and comments in earlier blueprints (history, not code). `grep -rn "spike" Sources Tests *.sh *.py` must be empty after deletion. Parent updates DECISIONS line 32 to name the deleting commit.
17. **Not checkable now, settled at build:** whether Core ML compiles/loads Ultra inside the `open`-launched hardened bundle with all three models loaded at once (the probe loaded Ultra only). Evidence it works: DECISIONS ("Ultra in the signed, hardened bundle under `open`"). If `AppController.start` fails in the bundle, `verify` writes the error into the report and the test shows it; no fallback.

# Blueprint

Files: `build.sh`, `app/Info.plist`, `app/app.entitlements`, `Package.swift` (edit), `Sources/TECore/Engine.swift` (edit), `Sources/TEUI/{AppController,Verify}.swift`, `Sources/TranscribeEverything/main.swift` (rewrite), `Tests/TECoreTests/{AppHarness,AppTests}.swift`. Delete `spike/`. Nothing else changes.

## Step 0 — commit, then delete the spike (first, so its history stays one `git show` away)
1. Commit the working tree as it stands (the spike is in it). Record the hash `H`.
2. After the rest of S6 is green: `git rm -r spike`. Parent writes `H` into DECISIONS line 32.
3. `grep -rn "spike" Sources Tests *.sh *.py` ⇒ no output. Remove any code comment found (the S4 `footprintMB` vendored comment, if it cites a spike path).

## `app/Info.plist`
The probe's plist verbatim (`spike/probe.sh` heredoc), as a file: `CFBundleIdentifier com.minh.transcribe-everything`, `CFBundleExecutable TranscribeEverything`, `CFBundleName TranscribeEverything`, `CFBundlePackageType APPL`, `CFBundleShortVersionString 0.0.1`, `CFBundleVersion 1`, `LSUIElement` true, `NSMicrophoneUsageDescription` "Transcribes the microphone when you attach it.", `NSAudioCaptureUsageDescription` "Transcribes audio from the apps you attach."

## `app/app.entitlements`
`spike/probe.entitlements` verbatim: one key, `com.apple.security.device.audio-input` = true. (Comment kept: hardened runtime silently withholds the mic consent prompt without it.)

## `build.sh`
```bash
#!/bin/bash
# Builds, signs with Developer ID, and installs the single app copy.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/TranscribeEverything.app"
STAGE=.build-app/TranscribeEverything.app

# No weaker identity: a changed signing identity resets the TCC grants.
ID="$(security find-identity -p codesigning -v | awk -F'"' '/Developer ID Application/{print $2; exit}')"
[ -n "$ID" ] || { echo "build.sh: no 'Developer ID Application' identity in the keychain; refusing a weaker one" >&2; exit 1; }

swift build -c release --product TranscribeEverything --scratch-path .build-app >&2
rm -rf "$STAGE"; mkdir -p "$STAGE/Contents/MacOS"
cp .build-app/release/TranscribeEverything "$STAGE/Contents/MacOS/"
cp app/Info.plist "$STAGE/Contents/"
codesign --force --options runtime --timestamp=none --entitlements app/app.entitlements --sign "$ID" "$STAGE" >&2
mkdir -p "$HOME/Applications"; rm -rf "$APP"; ditto "$STAGE" "$APP"
```
`--timestamp=none` is the probe's (no network at sign time). Order: identity check before `swift build`, so the refusal test (below) runs in milliseconds. Exactly one installed copy: `rm -rf` then `ditto`. `chmod +x` it.

## `Package.swift` (edit)
Add `.target(name: "TEUI", dependencies: ["TECore"])`. The executable depends on `["TECore", "TEUI", "FluidAudio"]` (`prefetch` still calls FluidAudio directly). The test target is unchanged (it launches the app; it never imports TEUI).

## `Sources/TECore/Engine.swift` (edit, two additive lines)
Inside `actor Engine`, beside the other stored properties:
```swift
private let activity = ProcessInfo.processInfo.beginActivity(options: .latencyCritical, reason: "live transcription")
deinit { ProcessInfo.processInfo.endActivity(activity) }
```
The engine's lifetime is the engine start (one `Engine` per start, DECISIONS), so held-while-running is the object's lifetime. A windowless agent is not App-Nap throttled while it lives. Add `import Foundation` if the file lacks it. No other Engine change; S4's `init` is whatever S4 left — `AppController` uses it unchanged.

## `Sources/TEUI/AppController.swift`
```swift
import FluidAudio
import TECore

/// The one construction of the running core; a normal launch and `verify` both use it.
public final class AppController {
    public let transcriber: Transcriber
    public let engine: Engine
    public let store: TranscriptStore

    public static func start(paths: Paths = Paths()) async throws -> AppController {
        async let transcriber = Transcriber.load()   // the three loads are independent: overlap them
        async let embedder = Embedder.load()
        async let vad = VadManager()
        let store = try TranscriptStore(paths: paths)
        let t = try await transcriber
        return AppController(transcriber: t, store: store,
                             engine: Engine(transcriber: t, embedder: try await embedder, vad: try await vad, store: store, config: ConfigStore()))
    }
    private init(transcriber: Transcriber, store: TranscriptStore, engine: Engine) { ... assign ... }
}
```
If a later `try await` throws while others are still loading, structured concurrency cancels and awaits the rest; the error propagates. No catch.

## `Sources/TEUI/Verify.swift` — the one scenario grammar
S7, S8, S10, S11 add a case to `Step` (and its `run`); no new entry point, no new file format.
```swift
import Foundation
import TECore

/// scenario.json: {"root": "<data root>", "steps": [{"op": "transcribe", "path": "<wav>"}, ...]}
struct Scenario: Decodable {
    let root: String
    let steps: [Step]
}

/// Tagged by "op" at decode; routed once, in `run`. A new op is a new case here and the compiler flags `run`.
enum Step: Decodable {
    case transcribe(path: String)

    private enum Key: String, CodingKey { case op, path }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .op) {
        case "transcribe": self = .transcribe(path: try c.decode(String.self, forKey: .path))
        case let op: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(op)")
        }
    }

    /// One JSON object per step: {"op": ..., ...result fields}.
    func run(_ app: AppController) async throws -> [String: Any] {
        switch self {
        case .transcribe(let path):
            var samples: [Float] = []
            for try await chunk in try FileSource(url: URL(fileURLWithPath: path), id: SourceID(rawValue: "verify"), tag: "v").chunks() { samples += chunk.samples }
            let t0 = ContinuousClock.now
            let text = try await app.transcriber.transcribe(samples).text
            let d = t0.duration(to: .now).components
            return ["op": "transcribe", "path": path, "text": text, "seconds": Double(d.seconds) + Double(d.attoseconds) * 1e-18]
        }
    }
}

public enum Verify {
    /// Runs the scenario through the same controller a normal launch builds; writes <scenario>.report.json beside it.
    public static func run(scenario url: URL) async throws {
        let report = url.deletingPathExtension().appendingPathExtension("report.json")
        do {
            let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url))
            let app = try await AppController.start(paths: Paths(root: URL(fileURLWithPath: scenario.root)))
            var results: [[String: Any]] = []
            for step in scenario.steps { results.append(try await step.run(app)) }
            try write(["bundleId": Bundle.main.bundleIdentifier as Any, "results": results], to: report)
        } catch {
            try write(["error": "\(error)"], to: report)
            throw error
        }
    }
    private static func write(_ obj: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
```
`Bundle.main.bundleIdentifier` is nil for a bare executable, so the report's `bundleId` proves the app identity (`as Any` keeps a nil as `Optional.none`; `JSONSerialization` then throws on it — a bare run fails loudly instead of reporting; this is intended, not a fallback). Steps run in order and sequentially: they share one transcriber and a latency step must not overlap another. The scenario file, `root`, and report are all the caller's temp paths: verify never touches `~/.transcribe-everything`.

## `Sources/TranscribeEverything/main.swift` (rewrite; `prefetch` body unchanged)
```swift
import AppKit
import FluidAudio
import Foundation
import TECore
import TEUI

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "prefetch" where args.count == 1:
    _ = try await Transcriber.load()
    _ = try await VadManager()
    _ = try await DiarizerModels.download()
    print("models ready")
case "verify" where args.count == 2:
    do { try await Verify.run(scenario: URL(fileURLWithPath: args[1])) } catch { FileHandle.standardError.write(Data("verify: \(error)\n".utf8)); exit(1) }
case nil:
    let controller = try await AppController.start()
    NSApplication.shared.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) { NSApplication.shared.run() }
default:
    FileHandle.standardError.write(Data("usage: TranscribeEverything [prefetch | verify <scenario.json>]\n".utf8))
    exit(2)
}
```
`prefetch`'s guard is now the first `case`; the exit code and usage line cover every other form. A launch with no arguments is the normal launch and has no UI until S9; it loads the core, holds the activity, and idles.

## `Tests/TECoreTests/AppHarness.swift` (test support, used by `AppTests` and by S7+)
```swift
import CoreGraphics
import CryptoKit
import Foundation

enum HarnessError: Error { case screenLocked, buildFailed(Int32, log: String), stale(String), app(String), noReport }

enum AppHarness {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let app = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/TranscribeEverything.app")
    static let staged = repo.appending(path: ".build-app/TranscribeEverything.app")
    static let label = "com.minh.transcribe-everything"
    static func executable(_ bundle: URL) -> URL { bundle.appending(path: "Contents/MacOS/TranscribeEverything") }

    /// Once per test process: build, sign, install, and prove the installed binary is the one just built.
    static let ready = Result<Void, Error> {
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { throw HarnessError.screenLocked }
        let log = resultsDir().appending(path: "build.log")
        let r = try sh("/bin/bash", [repo.appending(path: "build.sh").path], log: log)
        guard r.status == 0 else { throw HarnessError.buildFailed(r.status, log: log.path) }
        try assertSameBinary(executable(staged), executable(app))
    }

    static func assertSameBinary(_ fresh: URL, _ installed: URL) throws {
        if SHA256.hash(data: try Data(contentsOf: fresh)) != SHA256.hash(data: try Data(contentsOf: installed)) { throw HarnessError.stale(installed.path) }
    }

    /// Launches the installed app on the scenario through LaunchServices; returns the report. The LaunchAgent, if loaded, is stopped for the launch and restored right after.
    static func run(root: URL, steps: [[String: Any]]) throws -> [String: Any] {
        try ready.get()
        let dir = FileManager.default.temporaryDirectory.appending(path: "te-verify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scenario = dir.appending(path: "scenario.json"), report = dir.appending(path: "scenario.report.json")
        try JSONSerialization.data(withJSONObject: ["root": root.path, "steps": steps]).write(to: scenario)

        let domain = "gui/\(getuid())", plist = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
        let loaded = try sh("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0
        if loaded { _ = try sh("/bin/launchctl", ["bootout", "\(domain)/\(label)"]) }
        defer { if loaded { _ = try? sh("/bin/launchctl", ["bootstrap", domain, plist.path]) } }

        let out = resultsDir()
        _ = try sh("/usr/bin/open", ["-W", "-n", "--stdout", out.appending(path: "app.stdout").path, "--stderr", out.appending(path: "app.stderr").path, app.path, "--args", "verify", scenario.path])
        guard let data = try? Data(contentsOf: report) else { throw HarnessError.noReport }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let e = json["error"] as? String { throw HarnessError.app(e) }
        return json
    }

    /// Mutes system output for `body` and restores the previous mute state (not "unmuted").
    static func muted<T>(_ body: () throws -> T) throws -> T {
        FileHandle.standardError.write(Data("AppHarness: muting system output until this test ends; a call in progress goes silent\n".utf8))
        let before = try isMuted()
        try setMuted(true)
        defer { try? setMuted(before) }
        return try body()
    }
    static func isMuted() throws -> Bool { try sh("/usr/bin/osascript", ["-e", "output muted of (get volume settings)"]).out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" }
    static func setMuted(_ m: Bool) throws { _ = try sh("/usr/bin/osascript", ["-e", "set volume output muted \(m)"]) }

    /// Runs a tool to completion; `log` receives stdout+stderr, else stdout is returned in `out`.
    static func sh(_ exe: String, _ args: [String], env: [String: String] = [:], log: URL? = nil) throws -> (status: Int32, out: String) { ... }
}
```
`sh` body: `Process` with `executableURL`, `arguments`, `environment = ProcessInfo.processInfo.environment.merging(env) { $1 }`; with `log`: create the file, point stdout and stderr at one `FileHandle(forWritingTo:)`; otherwise stdout to a `Pipe` read to the end **before** `waitUntilExit` (avoids a full-pipe hang), stderr to the same pipe. Returns `(terminationStatus, output)`. Throws only if `run()` throws (executable missing). Every launch of the app is blocking by design (`open -W`); it blocks one cooperative thread of an XCTest async test, harmless at one worker.

Why `run(root:steps:)` takes steps as dictionaries: the grammar's Swift types live in TEUI (which tests do not import); the JSON is the contract, so tests write literals and stay independent of the code under test.

## `Tests/TECoreTests/AppTests.swift` (class `AppTests`, category App)
Shared, computed once per test process (one app launch for both result tests):
```swift
private static let launch = Result<[String: Any], Error> {
    let turns = try Fixtures.turns().indices.map { ["op": "transcribe", "path": Fixtures.turnWav($0).path] }
    let clip = ["op": "transcribe", "path": Fixtures.turnWav(3).path]          // 11.9 s
    return try AppHarness.run(root: FileManager.default.temporaryDirectory.appending(path: "te-app-" + UUID().uuidString),
                              steps: turns + [[String: Any]](repeating: clip, count: 9))
}
```
The data root is a temp directory the app creates; remove it in the test's teardown by deleting the `root` it passed (the launch result keeps it: store it in a `static var root`, deleted in `override class func tearDown()`).

1. **`testEveryTurnUnderTheAppIdentityIsTextIdenticalToTheOracle`.** `r = try launch.get()`; `XCTAssertEqual(r["bundleId"] as? String, "com.minh.transcribe-everything")`; `results = r["results"] as! [[String: Any]]` (21 entries); for i in 0..<12: `results[i]["text"] as? String == Fixtures.oracleText(i)` exactly. Write `app.md` to `resultsDir()`: a table `| turn | seconds | text |`, 12 rows. Setup: the real installed signed bundle, real Ultra, VAD and WeSpeaker loaded by the real controller. Falsifiable by: the app transcribing differently from the CLI oracle. Mutants: `Verify` transcribes through a `FileSource` that drops every 10th chunk ⇒ text differs ⇒ red; `Info.plist` without `CFBundleIdentifier` ⇒ bundleId assertion red.
2. **`testTwelveSecondDecodeUnderTheAppIdentityStaysAtTheProbeLevel`.** `try requireIdleMachine()` (same 3 lines as S4's `LiveTests` private helper: `getloadavg`, `l[0] > activeProcessorCount` ⇒ `XCTFail("machine load … decode time triples at load 26; latency bound does not apply")` and throw; S7 is the third user and lifts it to `Support.swift`). `ms = results[12...].map { $0["seconds"] as! Double }`; `warm = ms.dropFirst().sorted()` (8 values, the first of the 9 dropped as warm-up, as the probe did); `median = (warm[3] + warm[4]) / 2`; `XCTAssertLessThanOrEqual(median, 0.144)` — 2 × 72 ms (STRATA, probe-measured). Append the nine values and the median to `app.md`. Also assert `results[12...]` texts all equal `oracleText(3)`. Mutant: `build.sh` with `-c debug` and the matching `.build-app/debug` path ⇒ median far above 0.144 ⇒ red.
3. **`testInstalledAppIsDeveloperIDHardenedWithAudioEntitlementAndPlist`.** `try AppHarness.ready.get()`. `v = sh("/usr/bin/codesign", ["-dvv", app.path]).out` must contain `Authority=Developer ID Application:`, `flags=0x10000(runtime)` and `Identifier=com.minh.transcribe-everything`. `sh("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0`. `sh("/usr/bin/codesign", ["-d", "--entitlements", "-", app.path]).out` contains `com.apple.security.device.audio-input`. Read the installed `Contents/Info.plist` (`AppHarness.app`) with `PropertyListSerialization`: `LSUIElement == true`, `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription` are non-empty strings. Mutants (one `build.sh` edit each, then rebuild, then revert): `--sign -` ⇒ Authority assertion red; drop `--options runtime` ⇒ flags red; drop `--entitlements …` ⇒ entitlement red; delete the `NSAudioCaptureUsageDescription` key ⇒ plist red.
4. **`testBuildRefusesWithoutADeveloperIDIdentityAndLeavesTheInstalledAppAlone`.** Does not use `ready`. `shim = temporaryRoot(self)`; write `shim/security` = `#!/bin/sh\necho "     0 valid identities found"`, `chmod 755`. `before = SHA256` of `executable(app)` (installed by `ready`, so call `try AppHarness.ready.get()` first). `r = sh("/bin/bash", [repo/build.sh], env: ["PATH": shim.path + ":" + ProcessInfo.processInfo.environment["PATH"]!])`; assert `r.status == 1`, `r.out` contains `Developer ID Application`, and the installed hash equals `before` (build.sh stopped before any install). Mutant: `build.sh` falls back to `ID=-` when empty ⇒ status 0 ⇒ red.
5. **`testHarnessRefusesAStaleBinary`.** Two temp files, same size, one byte different; `XCTAssertThrowsError(try AppHarness.assertSameBinary(a, b))`; equal files ⇒ no throw. Mutant: compare file sizes only, or skip the compare ⇒ the throw assertion red (same size on purpose, so a size check cannot pass).
6. **`testMutedRestoresThePreviousState`.** For `start in [true, false]`: `setMuted(start)`; `muted { XCTAssertTrue(isMuted()) }`; `XCTAssertEqual(isMuted(), start)`. `addTeardownBlock { try? AppHarness.setMuted(initial) }` with `initial` read first. Mutant: restore `false` unconditionally ⇒ the `start = true` iteration red. This flips Minh's output mute for well under a second; the stderr warning prints before.

The refusal for a locked screen has no test: it reads one session key; forging a locked session is not possible without locking Minh's screen. Covered by uncertainty 4 and by `ready` throwing `screenLocked` in the test report with its own message.

## Attaining the human-verifiable result
1. `./test.sh App` under pacemaker (first run builds FluidAudio in `.build-app`: minutes). Read `test-results/<timestamp>/app.md`: 12 turn rows plus the nine 12 s decode times and their median.
2. `codesign -dvv ~/Applications/TranscribeEverything.app` ⇒ `Authority=Developer ID Application: Minh Trinh (BULCQM9J2V)`, `flags=0x10000(runtime)`. This is the stratum's human-verifiable line.
3. `ls ~/Applications | grep -c TranscribeEverything` ⇒ 1 (one copy).

## Order of work
`app/*` and `build.sh` ⇒ `Package.swift` + `TEUI` + `main.swift` ⇒ `Engine.swift` ⇒ `swift build` (debug, in `.build`) to catch compile errors ⇒ `AppHarness` + `AppTests` ⇒ `./test.sh App` ⇒ the six mutants ⇒ Step 0 deletion ⇒ full `./test.sh` (earlier strata unchanged) ⇒ fresh adversarial review.

## Not in S6
Menu, status item, permission requests, `AppSource`, `MicSource`, LaunchAgent plist and `install.sh` (S9–S15). The harness's loaded-agent branch runs for real first in S15. The `verify` grammar has one op; S7+ add theirs.
