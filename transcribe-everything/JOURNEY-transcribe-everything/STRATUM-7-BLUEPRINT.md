# Stratum 7 Blueprint — Per-app capture

Builds on S1–S5 (in the repo) and the S6 blueprint with its review corrections (`AppHarness`, `Verify`, `Step`, `AppController`, `resultsDir`, `temporaryRoot`, `muted` moved here). S8 reuses everything below.

# Uncertainties squashed

1. **One stream per `AppSource`, one delegate object.** `spike/Sources/Probe/main.swift:45-66` (`SCKAudio`) is `SCStreamOutput` and `SCStreamDelegate` in one object; `:98-110` (`sck2`) runs two such streams in one process. DECISIONS ("Two apps at once"): each held only its own speech, largest gap 65 ms.
2. **Every SCK call is compiled in the spike.** `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` (`:99`), `content.applications.first { $0.processID == … }` (`:101`), `SCStreamConfiguration` fields (`:103-105`), `SCContentFilter(display:including:exceptingWindows:)` (`:107`), `addStreamOutput(_:type:sampleHandlerQueue:)` (`:109`), `startCapture`/`stopCapture` (`:90-91`), `stream(_:didStopWithError:)` (`:49`), `withAudioBufferList` + `AVAudioFormat(cmAudioFormatDescription:)` + `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` (`:53-62`). `excludesCurrentProcessAudio` stays unset, as in `sck2`.
3. **Buffers may be any size.** `SourcePipeline.run` needs only `c.index == base + samples.count` (the `precondition`); `PipelineTests.testVadGridDoesNotDependOnTheSourcesBufferSize` runs 3000-sample chunks to identical segments. One SCK buffer is one `Chunk`.
4. **Format is marked once at the boundary.** With `sampleRate = 16000`, `channelCount = 1` the first buffer must be 16 kHz mono Float32. `Tap` checks it on the first buffer, caches that `AVAudioFormat`, and reuses it (a stream's format cannot change).
5. **`didTerminateApplicationNotification` arrives with no `NSApplication`.** Probed (`/tmp/te-s7-probe/main.swift`: top-level `await`, TextEdit via `open -g -j -n`, then `kill`): `TERMINATED <pid>` 4 s later. `verify` has no run loop (S6), so this matters and holds. `userInfo[NSWorkspace.applicationUserInfoKey]` is an `NSRunningApplication`.
6. **Stall guard.** `ContinuousClock` counts Mac sleep, so after wake the guard fires at its first check. It arms after `startCapture()` returns, so start-up never counts as a stall. 1 s = DECISIONS "Stall = failure" (65 ms largest gap × 15). The default lives in `StallGuard.limit` only; S8 reuses the type.
7. **No `didStopWithError` on app exit.** DECISIONS: SCK keeps delivering silence. The terminate observer is the only end signal; it registers before the SCK lookup so an exit during start-up is not missed. A pid already gone at lookup throws `Failure.noApp`.
8. **Chrome is launched directly with `Process`.** Probed now: `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir=<tmp> … &` gives pid `$!`; `NSRunningApplication(processIdentifier:)` is `com.google.Chrome`; `kill` of that pid leaves no process with the profile (`pgrep -f user-data-dir=<tmp>` empty after 2 s). So no `open`, `pgrep`, `ps` or `pkill`, and Minh's own Chrome is never touched. Earlier headless probe: a `file://` page's `fetch('go.txt')` succeeds with `--allow-file-access-from-files`, fails without; so the page can wait for `go.txt`, then `play()` (autoplay flag from `spike/chrome_capture.sh`). `go.txt` stays: audio must start after capture is attached.
9. **Clock alignment.** The capture clock starts at attach, audio starts later. Offset = first speech frame of the capture − first speech frame of the fixture, frame 320 samples, threshold RMS 0.01 (`fixtures.py:60`).
10. **Sample clock tracks wall clock.** DECISIONS: 8.04 s of frames in an 8 s capture. Test: `maxClockDrift ≤ 0.5` (VAD tolerance, DECISIONS ±0.5). A mutant dropping silent buffers drifts by the pause length.
11. **Pause test checks the clock, not the words.** QuickTime pause latency (hundreds of ms) is bigger than the 0.8 s gaps, so the test uses one 11.9 s clip (turn 3), pauses at 3 s, and checks the recorded silent hole and line edges within ±0.5 s.
12. **Latency formulas are S4's**, second user, so lifted to `Latency` (below). Sample → wall time: the wall time of the chunk that carried it, backed off by the samples after it, so capture delivery lag cancels. One `embedMax` per source.
13. **Fixtures.** `conversation.wav` 99.05 s, turn 0 starts at 0.0, speakers per turn `4970, 4992, 5105` ×4; `turns/03.wav` 11.9 s.
14. **QuickTime does not autoplay an opened file** (`spike/play_and_capture.sh` paused mode captures silence). `osascript` to QuickTime works from the agent shell, screen locked or not (parent checked: `get name`, `quit`, exit 0). Mute needs no permission (S6).
15. **`TECore` imports AppKit** (`NSWorkspace`): "no GUI" in STRATA means no windows. `import ScreenCaptureKit` autolinks; no Package change.
16. **OTHER.md.** "S6: `AppHarness` mutes output … add a warning" resolved: `muted` prints a stderr warning and restores the previous state (below). Idle wait rejected: no cheap "call in progress" signal. Parent: delete that item.
17. **Settled at build** (each needs a capture): first measured drift; Ultra loads in the bundle with all three models (S6 uncertainty 17); SCK lists a directly launched Chrome (`Failure.noApp` shows it); the first-buffer delay after `startCapture` — if it exceeds 1 s a false stall appears as `ended != []` in tests 4–7. A red from any is a finding: report, never loosen.

# Blueprint

New: `Sources/TECore/{StallGuard,AppSource}.swift`, `Sources/TEUI/VerifyCapture.swift`, `Tests/TECoreTests/{CaptureTests,CaptureSupport}.swift`. Edited: `Sources/TECore/Transcriber.swift`, `Sources/TEUI/{Verify,AppController}.swift`, `Tests/TECoreTests/{AppHarness,Support,PipelineSupport,LiveTests,PipelineTests}.swift`. Nothing else.

## `Sources/TECore/StallGuard.swift` (public: S8 uses it)
```swift
import Foundation
import os

/// Capture delivers buffers continuously, silence included, so a gap longer than `limit` means capture stopped.
public final class StallGuard: Sendable {
    public static let limit: Duration = .seconds(1)  // DECISIONS: 15× the largest measured gap
    public struct Stalled: Error, CustomStringConvertible {
        public let limit: Duration
        public var description: String { "no audio buffers for more than \(limit)" }
    }
    public let limit: Duration
    private let last = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    public init(limit: Duration = StallGuard.limit) { self.limit = limit }
    public func beat() { last.withLock { $0 = .now } }

    /// Counts from the call. Throws `Stalled` at the first gap of `limit`; returns when cancelled.
    public func watch() async throws {
        beat()
        while true {
            let seen = last.withLock { $0 }
            do { try await Task.sleep(until: seen.advanced(by: limit), clock: .continuous) } catch { return }  // only CancellationError
            if last.withLock({ $0 }) == seen { throw Stalled(limit: limit) }
        }
    }
}
```
Sleeps to `last + limit` and fires only if no beat moved `last`: a beat at 0.9·limit restarts the count; a gap of `limit` always fires.

## `Sources/TECore/AppSource.swift`
```swift
import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit
import os

public final class AppSource: AudioSource {
    public enum Failure: Error { case noApp(pid_t), noDisplay, format(String) }
    public let id: SourceID, tag: String
    private let pid: pid_t, stallLimit: Duration
    private let continuation = OSAllocatedUnfairLock<AsyncThrowingStream<Chunk, Error>.Continuation?>(initialState: nil)

    public init(pid: pid_t, id: SourceID, tag: String, stallLimit: Duration = StallGuard.limit) { /* assign */ }

    public func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { out in
            continuation.withLock { $0 = out }
            let stall = StallGuard(limit: stallLimit), tap = Tap(out, stall), pid = pid
            let exit = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { n in
                if (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == pid { out.finish() }
            }
            let task = Task {
                var stream: SCStream?
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    try Task.checkCancellation()  // stopped during the lookup: build nothing
                    guard let app = content.applications.first(where: { $0.processID == pid }) else { throw Failure.noApp(pid) }
                    guard let display = content.displays.first else { throw Failure.noDisplay }
                    let cfg = SCStreamConfiguration()
                    cfg.capturesAudio = true
                    cfg.sampleRate = Chunk.sampleRate
                    cfg.channelCount = 1
                    cfg.width = 2; cfg.height = 2  // video is not consumed; smallest frame
                    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                    let s = SCStream(filter: SCContentFilter(display: display, including: [app], exceptingWindows: []), configuration: cfg, delegate: tap)
                    try s.addStreamOutput(tap, type: .audio, sampleHandlerQueue: tap.queue)
                    try await s.startCapture()
                    stream = s
                    try await stall.watch()  // starts counting only now; ends on stall (throws) or cancel
                } catch { out.finish(throwing: error) }
                try? await stream?.stopCapture()  // after the outcome is decided; an already-stopped stream throws and changes nothing
            }
            out.onTermination = { _ in
                NSWorkspace.shared.notificationCenter.removeObserver(exit)
                task.cancel()
            }
        }
    }
    public func stop() { continuation.withLock { $0?.finish() } }
}

/// Output and delegate in one object, as in the probe. Every outcome goes through `out.finish`; the first call wins.
private final class Tap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let out: AsyncThrowingStream<Chunk, Error>.Continuation
    let queue = DispatchQueue(label: "AppSource.samples")  // serial: `next` and `format` live on it
    private let stall: StallGuard
    private var next = 0, format: AVAudioFormat?
    init(_ out: AsyncThrowingStream<Chunk, Error>.Continuation, _ stall: StallGuard) { self.out = out; self.stall = stall }

    func stream(_ s: SCStream, didStopWithError error: Error) { out.finish(throwing: error) }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        do {
            if format == nil {
                guard let desc = sb.formatDescription else { throw AppSource.Failure.format("buffer without format") }
                let f = AVAudioFormat(cmAudioFormatDescription: desc)
                guard f.sampleRate == Double(Chunk.sampleRate), f.channelCount == 1, f.commonFormat == .pcmFormatFloat32 else { throw AppSource.Failure.format("\(f)") }
                format = f
            }
            stall.beat()
            let samples: [Float] = try sb.withAudioBufferList { abl, _ in
                let buf = AVAudioPCMBuffer(pcmFormat: format!, bufferListNoCopy: abl.unsafePointer)!
                return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
            }
            out.yield(Chunk(samples: samples, index: next))
            next += samples.count
        } catch { out.finish(throwing: error) }
    }
}
```
Behaviour: app quits ⇒ `finish()` ⇒ pipeline flushes (`SourceEnd.error == nil`). `didStopWithError`, bad format, missing app/display, `Stalled` ⇒ `finish(throwing:)` ⇒ pipeline commits the open segment, then `SourceEnd(error:)` (S2/S4, unchanged). Stream termination cancels the task, which stops the SCStream.

## `Sources/TECore/Transcriber.swift` (edit)
`Priority` and `Decode` become `Codable`; `Decode` gains `public init(priority:submitted:started:finished:)`. They cross the report's JSON boundary, so tests decode them with plain `import TECore` and no mirror type.

## `Sources/TEUI/AppController.swift` (edit)
Add `public let paths: Paths`, set in `start(paths:)` and the private init.

## `Sources/TEUI/Verify.swift` (edit)
`enum Step`: add `case capture(CaptureSpec)`; in `init(from:)`: `case "capture": self = .capture(try CaptureSpec(from: decoder))`; in `run`: `case .capture(let spec): return try await app.capture(spec)`.

## `Sources/TEUI/VerifyCapture.swift`
```swift
import Foundation
import TECore
import os

/// {"op":"capture","sources":[{"id":"qt","kind":"app","tag":"QuickTime","pid":123}],"stallLimit":1.0}   (stallLimit optional, seconds)
struct CaptureSpec: Decodable {
    enum Src: Decodable {
        case app(id: String, tag: String, pid: pid_t)
        private enum Key: String, CodingKey { case id, kind, tag, pid }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "app": self = .app(id: try c.decode(String.self, forKey: .id), tag: try c.decode(String.self, forKey: .tag), pid: try c.decode(pid_t.self, forKey: .pid))
            case let k: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(k)")
            }
        }
    }
    let sources: [Src]
    let stallLimit: Double?

    /// The one place a source kind becomes an `AudioSource`; a new kind is a new case here.
    func build() -> [any AudioSource] {
        let limit = stallLimit.map { Duration.seconds($0) } ?? StallGuard.limit
        return sources.map { src in
            switch src { case .app(let id, let tag, let pid): AppSource(pid: pid, id: SourceID(rawValue: id), tag: tag, stallLimit: limit) }
        }
    }
}

private struct Arrival: Encodable, Sendable { let end: Int, wall: Date }   // wall = when the chunk ending at sample `end` arrived
private struct Shown: Encodable, Sendable { let t: Date, lines: [String: Int], tails: [String] }   // one per store change
private struct Ended: Encodable, Sendable { let id: String, error: String? }
private struct SourceReport: Encodable { let file: String, arrivals: [Arrival] }
private struct CaptureReport: Encodable {
    let op = "capture"
    let ended: [Ended], sources: [String: SourceReport], decodes: [Decode], shown: [Shown], lines: [Line]
}
```
`Recorded`: forwards any `AudioSource`, appends every sample to `<id>.f32` (raw little-endian Float32), notes arrivals. The file is the test's ground truth for what capture delivered.
```swift
private final class Recorded: AudioSource, @unchecked Sendable {
    let base: any AudioSource
    var id: SourceID { base.id }
    var tag: String { base.tag }
    let started: AsyncStream<Void>   // finishes at the first chunk, or at the stream's end/failure if none came
    let arrivals = OSAllocatedUnfairLock<[Arrival]>(initialState: [])
    private let startedC: AsyncStream<Void>.Continuation
    private let handle: FileHandle
    init(_ base: any AudioSource, file: URL) throws { /* createFile(atPath:contents:nil); handle = FileHandle(forWritingTo: file); (started, startedC) = AsyncStream.makeStream(of: Void.self) */ }
    func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                defer { startedC.finish() }
                do {
                    for try await chunk in base.chunks() {
                        try handle.write(contentsOf: chunk.samples.withUnsafeBytes { Data($0) })
                        arrivals.withLock { $0.append(Arrival(end: chunk.index + chunk.samples.count, wall: Date())) }
                        startedC.finish()
                        c.yield(chunk)
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func stop() { base.stop() }
}
```
`extension AppController { func capture(_ spec: CaptureSpec) async throws -> [String: Any] }`:
```
root = paths.root
recs = try spec.build().map { try Recorded($0, file: root/"\($0.id.rawValue).f32") }
decodes, shown, early = OSAllocatedUnfairLock arrays
await transcriber.observe { decodes.append($0) }
watcher = Task { for await _ in store.changes { s = await store.snapshot(); shown.append(Shown(t: Date(), lines: Dictionary(grouping: s.lines, by: \.src.rawValue).mapValues(\.count), tails: s.tails.map(\.src.rawValue))) } }
for r in recs { await engine.attach(r) }
for r in recs { for await _ in r.started {} }          // every source delivered, or already failed
write empty file root/"ready"
await withTaskGroup(of: Void.self) { g in
    g.addTask { for await e in self.engine.ended { early.append(Ended(id: e.id.rawValue, error: e.error.map { "\($0)" })); if early.count == recs.count { return } } }
    g.addTask { while !FileManager.default.fileExists(atPath: (root/"stop").path), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) } }
    await g.next(); g.cancelAll()                       // all sources ended, or the test said stop
}
for r in recs { await engine.detach(r.id) }             // no-op for ended sources; commits an open segment
watcher.cancel(); await transcriber.observe(nil)
report = CaptureReport(ended: early, sources: [id: SourceReport(file: "\(id).f32", arrivals: r.arrivals)], decodes: decodes, shown: shown, lines: await store.snapshot().lines)
return try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
```
`ended` lists only ends seen before stop. The 100 ms stop poll is test pacing (≪ the second-scale bounds), not product behaviour. `ready` and `stop` are the whole control channel; the test owns `root`. JSON dates use `JSONEncoder`'s default; tests decode with the default.

## Existing-test edits (mechanical lifts; S4's tests stay green with their mutants)
- `Support.swift`: add `struct Busy: Error {}` and `func requireIdleMachine() throws`, moved verbatim from `LiveTests.swift` (internal). Delete the private copies.
- `PipelineSupport.swift`: add
```swift
/// DECISIONS latency bounds. Queue wait itself is never added, so a starved commit goes red.
struct Latency {
    let records: [Decode]
    func ran(_ r: Decode) -> Double { r.finished.timeIntervalSince(r.started) }
    func inflight(_ r: Decode) -> Double { records.first { $0.started < r.submitted && r.submitted < $0.finished && $0.started != r.started }.map(ran) ?? 0 }
    func ahead(_ r: Decode) -> [Decode] { records.filter { r.submitted <= $0.started && $0.started < r.started } }
    func commitBound(_ c: Decode, embedMax: Double, sources: Int) -> Double { 1.28 + ran(c) + Double(sources) * embedMax + inflight(c) + ahead(c).map(ran).reduce(0, +) }
    func firstBound(_ p: Decode) -> Double { 0.866 + ran(p) + inflight(p) + ahead(p).map(ran).reduce(0, +) }
}
/// Max embed duration while a decode runs (same hardware): LiveTests' 30-embed contention block, moved verbatim.
func measureEmbedMax(_ tr: Transcriber, _ embedder: Embedder, _ audio: [Float]) async throws -> Double
func cuts(_ lines: [Line]) -> Int { zip(lines, lines.dropFirst()).filter { $1.start == $0.end && $1.spk == $0.spk }.count }
```
- `LiveTests.testThreeSourcesInRealTimeMeetTheLatencyBounds`: `embedMax = try await measureEmbedMax(tr, embedder, audio)`; `let lat = Latency(records: records)`; use `lat.ahead`, `lat.commitBound(c, embedMax:, sources: 3)`, `lat.firstBound(p)`; delete the local `inflight`, `ahead` and the private `ran`. Assertions unchanged. `PipelineTests`: delete its private `cuts`. Run `./test.sh Live` and `./test.sh Pipeline` green first.
- `AppHarness.swift` (S6): add
```swift
final class Launch {
    let report: Task<[String: Any], Error>
    private let done = OSAllocatedUnfairLock(initialState: false)
    init(root: URL, steps: [[String: Any]]) { report = Task.detached { defer { done = true }; return try AppHarness.run(root: root, steps: steps) } }
    /// Returns when the app wrote `ready`; throws the app's own error if it exits first.
    func ready(in root: URL) async throws {
        while !FileManager.default.fileExists(atPath: root.appending(path: "ready").path) {
            if done.withLock({ $0 }) { _ = try await report.value; throw HarnessError.noReport }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
```
and, as the S6 correction moved them here: `muted<T>(_ body: () async throws -> T) async throws -> T` (stderr warning first; `before = isMuted()`; `setMuted(true)`; `defer { try? setMuted(before) }` so a throw restores too), `isMuted`, `setMuted`, exactly as S6's `AppHarness` section defines them apart from the async body.

## `Tests/TECoreTests/CaptureSupport.swift`
```swift
let captureTail = 5.0   // pacing: QuickTime start ≤ 2 s (play_and_capture.sh waits 1 s) + commit bound 1.28 s + a decode; too short fails the WER check, never passes it
let frame = 320, speechThreshold: Float = 0.01   // fixtures.py:60

func eventually(_ what: String, _ body: () async throws -> Bool) async throws  // polls every 50 ms, 15 s deadline (chrome_capture.sh: 30 × 0.5 s); throws "\(what) never happened"
func floats(_ f32: URL) throws -> [Float]
func speechFrames(_ x: [Float]) -> [Bool]  // per 320-sample frame: sqrt(mean(x²)) >= speechThreshold
func speechOnset(_ x: [Float]) -> Int      // speechFrames(x).firstIndex(of: true)! * frame
func speechRMS(_ x: [Float]) -> Float      // RMS over the samples of speech frames only (S8 compares runs; silence would measure start jitter)
func lastSpeechEnd(_ x: [Float]) -> Double // (lastIndex(of: true)! + 1) * frame / 16000
func silentRuns(_ x: [Float]) -> [(start: Double, end: Double)]  // maximal false runs between the first and last true frame, seconds
func maxClockDrift(_ a: [Arrival]) -> Double   // max |(wall_i − wall_0) − (end_i − end_0)/16000|
func wallTime(of sample: Int, _ a: [Arrival]) -> Date  // c = first arrival with end > sample; c.wall − (c.end − sample)/16000 s

struct Arrival: Decodable { let end: Int; let wall: Date }
struct Report: Decodable {
    struct Ended: Decodable { let id: String; let error: String? }
    struct Src: Decodable { let file: String; let arrivals: [Arrival] }
    struct Shown: Decodable { let t: Date; let lines: [String: Int]; let tails: [String] }
    let ended: [Ended]; let sources: [String: Src]; let decodes: [Decode]; let shown: [Shown]; let lines: [Line]
}
struct Captured { let report: Report; let samples: [String: [Float]]; let transcript: URL }   // lines: report.lines

func appSource(_ id: String, _ tag: String, _ pid: Int) -> [String: Any]   // ["id", "kind": "app", "tag", "pid"]

/// One launch of the app's `capture` op. `during` runs once every source delivers; `stop` is written when it returns. `extra` is merged into the op's JSON (e.g. ["stallLimit": 0.001]).
func runCapture(_ test: XCTestCase, _ sources: [[String: Any]], extra: [String: Any] = [:], during: () async throws -> Void) async throws -> Captured
```
`runCapture` body: `root = temporaryRoot(test)`; `addTeardownBlock { try? Data().write(to: root/"stop") }` (an aborted test never leaves the app running); `launch = Launch(root:, steps: [["op": "capture", "sources": sources].merging(extra) { $1 }])`; `try await launch.ready(in: root)`; `try await during()`; write `root/stop`; `r = try await launch.report.value`; `report = JSONDecoder().decode(Report.self, from: JSONSerialization.data(withJSONObject: (r["results"] as! [[String: Any]])[0]))`; `samples[id] = floats(root/report.sources[id].file)` per source; `transcript` = the single `*.jsonl` in `root/transcripts` (copied into results by the tests that print it).

```swift
/// QuickTime Player under test control. Refuses to start if one is running: the test quits it, and it may be Minh's.
enum QuickTime {
    static func open(_ wav: URL, _ test: XCTestCase) async throws -> Int  // `pgrep -x "QuickTime Player"` must be empty; `open -g -a "QuickTime Player" wav`; eventually pid exists and `count documents` == "1"; addTeardownBlock { try? quit() }
    static func play() throws, pause() throws, quit() throws             // osascript `with timeout of 10 seconds` / `tell application "QuickTime Player" to play document 1` / `pause document 1` / `quit`; status ≠ 0 ⇒ throw with the output
}

/// A throwaway Chrome (own profile) whose page plays `wav` once `go()` creates go.txt.
struct Chrome {
    let process: Process, dir: URL
    var pid: Int { Int(process.processIdentifier) }
    static func launch(_ test: XCTestCase, playing wav: URL) throws -> Chrome
    func go() throws { try Data().write(to: dir.appending(path: "go.txt")) }
}
```
`Chrome.launch`: `dir = temporaryRoot(test)` (created); write `dir/page.html`:
`<audio id=a src="WAV_ABSOLUTE_URL"></audio><script>const t=setInterval(()=>fetch('go.txt').then(()=>{clearInterval(t);a.play()}).catch(()=>{}),100)</script>`;
`Process` at `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`, arguments `--user-data-dir=<dir>/profile --no-first-run --no-default-browser-check --autoplay-policy=no-user-gesture-required --allow-file-access-from-files --new-window file://<dir>/page.html`, stdout and stderr `nullDevice`; `run()`; `addTeardownBlock { process.terminate() }` (runs before the directory removal: teardown blocks run last-in first-out).

## `Tests/TECoreTests/CaptureTests.swift` (class `CaptureTests`, category Capture)
Every real test sets `executionTimeAllowance` to its run length + 120 s and runs its whole body inside `try await AppHarness.muted { … }`. Every QuickTime test also calls `requireIdleMachine()` at start and end.

**In-process (no permissions, no app):**
1. `testBeatsCloserThanTheLimitNeverStall` — `requireIdleMachine()`. `g = StallGuard(limit: .seconds(0.5))`; `w = Task { try await g.watch() }`; 8 × (sleep 0.3 s; `g.beat()`); `w.cancel()`; `try await w.value` must not throw. Mutant: `seen.advanced(by: limit / 2)` ⇒ throws at 0.25 s ⇒ red.
2. `testASilenceOverTheLimitThrowsStalledNotBeforeTheLimit` — `g.watch()` in a task; 3 × (sleep 0.1 s; `g.beat()`); `let t = Date(); g.beat()` (before the final beat, so the fire time ≥ `t` + 0.5); `do { try await w.value; XCTFail("no stall") } catch let e as StallGuard.Stalled { XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t), 0.5); XCTAssertEqual(e.limit, .seconds(0.5)) }`. Mutants: `limit / 2` ⇒ elapsed < 0.5 red; `watch` returns instead of throwing ⇒ `XCTFail` red; never fires ⇒ the 30 s `executionTimeAllowance` red.
3. `testMutedRestoresThePreviousState` — S6's test: `for start in [true, false]`: `setMuted(start)`; inside `muted { XCTAssertTrue(isMuted()) }`; afterwards `isMuted() == start`; teardown restores `initial`. Also: a body that throws still restores (`do { try await AppHarness.muted { throw Boom() } } catch {}`, then state == start). Mutants: restore `false` unconditionally ⇒ `true` iteration red; `defer` replaced by restore-after-body ⇒ throw case red.

**Real SCK (each test is one launch of `capture`):**
4. **`testQuickTimeConversationMatchesOracleThreeSpeakersAndLatency`.** Before the capture: `tr`, `embedder` from `Models`; `conv` = `collect(FileSource(conversationWav))` samples; `embedMax = measureEmbedMax(tr, embedder, conv)`. `pid = QuickTime.open(conversationWav)`; `cap = runCapture(self, [appSource("qt","QuickTime",pid)]) { QuickTime.play(); sleep conv.count/16000 + captureTail }`.
   - `s = cap.samples["qt"]!`; `off = Double(speechOnset(s) − speechOnset(conv)) / 16000`. `maxClockDrift(arrivals) ≤ 0.5`; `report.ended == []`.
   - Shift each line by `−off`; group by `turnOf`; every turn has ≥ 1 line. Per turn *i*: `wer(turns[i].text, joined).errors ≤ wer(turns[i].text, oracleText(i)).errors + cuts(group)`; corpus sum likewise (S2's rule).
   - Speakers: `Set(all spk).count == 3`; label of a turn = its most frequent `spk`; for all turn pairs: same `turns[i].speaker` ⇔ same label.
   - Latency (S4's method, `lat = Latency(records: report.decodes)`): per turn *j* with `w = oracleWords(j)`, `sample(x) = Int((off + turns[j].start + x) * 16000)`: `lastWord = wallTime(of: sample(w.last.end))`, `onset = wallTime(of: sample(w.first.start))`; `t` = max `Line.t` of the turn; `c` = the commit decode with the greatest `finished ≤ t`; assert `lat.ahead(c)` are all commits, and `t − lastWord ≤ lat.commitBound(c, embedMax:, sources: 1)`. First text: the earliest `shown` entry with `lines["qt"] ≥ (lines in earlier turns)` and `"qt" ∈ tails`; `p` = the provisional decode with the greatest `finished ≤ first.t`; `first.t − onset ≤ lat.firstBound(p)`.
   - Output: `capture.md` in `resultsDir()`: `| turn | start–end | errors ours/oracle | first text s | bound | commit s | bound | text |` plus `max clock drift`; copy `cap.transcript` to `capture-conversation.jsonl`.
   - Mutants: `cfg.sampleRate = 48000` ⇒ `Failure.format` ⇒ lines missing ⇒ red; `Chunk(index: 0)` constant ⇒ pipeline precondition crash ⇒ red.
5. **`testTenSecondPauseKeepsBoundariesAndTheClockOnWallTime`.** `clip = turnWav(3)`; `pid = QuickTime.open(clip)`; `runCapture { play; sleep 3; pause; sleep 10; play; sleep (11.9 − 3) + captureTail }`. `hole = silentRuns(s).max { length }`. Assert `maxClockDrift ≤ 0.5`; `hole.end − hole.start ≥ 9.5` (≥ 10 s paused; 0.5 s of fade below threshold); some line has `|end − hole.start| ≤ 0.5` and some `|start − hole.end| ≤ 0.5`; `ended == []`. Mutants: `AppSource` drops all-zero buffers ⇒ drift ≈ 10 s red, hole < 9.5 red; pipeline loses index continuity ⇒ boundary assertions red.
6. **`testQuittingQuickTimeEndsTheSourceWithItsLastLineCommitted`.** `runCapture { play; sleep 8; QuickTime.quit(); sleep captureTail }` (turn 1 spans 3.8–10.4 s). Assert `ended.count == 1`, `ended[0].id == "qt"`, `ended[0].error == nil`; `lines` non-empty; `lines.last!.end ≥ lastSpeechEnd(s) − 0.5` and `≤ Double(s.count)/16000`. Mutant: delete `addObserver` ⇒ no end (silence keeps coming) ⇒ `ended` empty ⇒ red.
7. **`testQuickTimeAndChromeTogetherKeepOnlyTheirOwnSpeech`.** `cont = collect(FileSource(continuousWav))` samples; `chromeWhole = tr.transcribe(cont).text`; `chrome = Chrome.launch(self, playing: continuousWav)`; `pid = QuickTime.open(conversationWav)`; `runCapture(self, [appSource("qt","QuickTime",pid), appSource("ch","Chrome",chrome.pid)]) { QuickTime.play(); chrome.go(); sleep D + captureTail }`. Assert `ended == []`. QuickTime lines (`src == "qt"`): `wer(joined turn texts, joined lines).errors ≤ Σ per-turn oracle errors + cuts`. Chrome lines: `wer(continuousText(), joined).errors ≤ wer(continuousText(), chromeWhole).errors + cuts`; `maxClockDrift ≤ 0.5` per source. Isolation: `onlyConv = words(conversation truth) − words(continuous truth)`, `onlyCont` the reverse (`words = Set(normalize)`); `words(qt lines) ∩ onlyCont == ∅`, `words(chrome lines) ∩ onlyConv == ∅`. Mutants: both taps write one shared continuation ⇒ each side holds the other's words ⇒ red; the filter built on a window list instead of `including: [app]` (no helper audio) ⇒ Chrome has no lines ⇒ red.
8. **`testStallLimitBelowTheBufferCadenceFailsTheSourceWithTheReason`.** QuickTime opened with the clip, never played; `runCapture(self, [appSource(…)], extra: ["stallLimit": 0.001]) { sleep captureTail }`. Assert `ended.count == 1` and `ended[0].error` contains `"no audio buffers for more than"`. Proves the guard is wired into the real stream with the configured limit (buffers cannot arrive every 1 ms). Mutant: delete the `watch` call ⇒ `ended` empty ⇒ red.

Each mutant: one edit to a source file, run the single named test, see it red, revert, see it green.

## Steps to attain the human-verifiable result
1. Order: `StallGuard` + tests 1–3 (no app) ⇒ the lifts, `./test.sh Live` and `./test.sh Pipeline` green ⇒ `AppSource` ⇒ `VerifyCapture` + `Verify`/`AppController`/`Transcriber` edits ⇒ `Launch`, `CaptureSupport` ⇒ tests 4–8 under pacemaker with `./test.sh Capture` (≈ 100 + 27 + 25 + 105 + 8 s plus an app start each). Never use Minh's QuickTime; the tests refuse a running one.
2. The mutants above, each reverted; full `./test.sh` green.
3. Read `test-results/<timestamp>/capture.md` and `capture-conversation.jsonl`.
4. Minh's check, second display and Safari, one block per app:
```
S=$(mktemp -d); P=$(pgrep -x Safari | head -1)
printf '{"root":"%s","steps":[{"op":"capture","sources":[{"id":"app","kind":"app","tag":"Safari","pid":%s}]}]}' "$S" "$P" > "$S/s.json"
(sleep 60; touch "$S/stop") & open -W -n ~/Applications/TranscribeEverything.app --args verify "$S/s.json"; cat "$S"/transcripts/*.jsonl
```
   Lines appear, or the limit (an app on the second display delivers nothing; an app with no audio session) goes into DECISIONS. The filter is `content.displays.first`; audio of an app on another display, if missed, is the recorded limit, not a patch here.

## Not in S7
Mic (S8), menu/attach/permissions (S9–S10), window catalog, LaunchAgent. `AppSource` takes a pid; resolving one from a window or bundle id is S9/S10.

# Review corrections (apply at build)
- `QuickTime.quit()` ends with `eventually("QuickTime exited") { pgrep -x is empty }`.
- `Launch.init`: capture a local `let` lock so the closure compiles; set `done` under the lock.

# Build findings (supersede the sections above)
- `AppSource` restarts its stream when the app gains an audio helper (`AudioHelpers`): test 7 found attach-then-play silent in Chrome. See DECISIONS.
- `Chrome.launch` uses `open -g -n` and finds the pid with `pgrep`, so Chrome, not the test, is responsible for its helper.
- Test 4 checks speakers with `speakerAccuracy` (lifted from `SpeakerTests`). Tests 4 and 7 allow `captureExcess*` words; the oracle bound assumed identical samples.
- `runCapture` holds the display awake; SCK lists no display while it sleeps. Tests 4–7 call `requireNoFailure()` so a failed source reports its reason.
- A restart starts the new stream first, adopts it, then stops the old one, so no audio gap exists and the stall guard never fires for a restart (S7 review).
