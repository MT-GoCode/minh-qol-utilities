# Stratum 8 Blueprint — Microphone source

Builds on S7 (`StallGuard`, `CaptureSpec`, `Recorded`, `runCapture`, `QuickTime`, `speechRMS`, `muted`) as its blueprint defines them. S8 adds one source kind to the same `capture` op; there is no second op and no second report.

# Uncertainties squashed

1. **Converter (probed, no mic).** One persistent `AVAudioConverter(from: mono Float32 @ R, to: mono Float32 @ 16 kHz)`, one 4096-frame buffer per call via a one-shot input block (`.haveData` once, then `.noDataNow`), output capacity `ceil(4096·16000/R) + 1`. 50 buffers: R=48000 ⇒ 68,261 out (ideal 68,266.7); 44100 ⇒ 74,298 (74,303.9); 24000 ⇒ 136,522 (136,533.3). Per call the output fits the capacity. Status is always `.inputRanDry` with error nil (normal for a one-shot block), so only `.error` is a failure. The deficit is filter priming, ≤ 11.5 samples at all three rates ⇒ test bound 16 samples.
2. **Chunk size is free.** `SourcePipeline` needs only contiguity (`precondition(c.index == base + samples.count)`, `SourcePipeline.swift:81`) and re-slices to 4096 itself (`:83`). One chunk per tap buffer (≈1365 samples at 48 kHz). A restart keeps `emitted` running, so indices stay contiguous; the sample clock then lags wall clock by the restart gap (lost audio is not invented).
3. **Mic code is the spike's, minus preconditions.** `builtInMic()` (`spike/.../main.swift:225`) force-unwraps and preconditions; `micCapture` (`:247`) selects the device with `AudioUnitSetProperty(input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, …)` on the plain (non-voice-processing) path and taps `bufferSize: 4096, format: input.outputFormat(forBus: 0)`. DECISIONS: peak 0.15, device "MacBook Pro Microphone", largest normal gap 107 ms. Clamshell has no built-in input ⇒ `MicError.noBuiltInMic`, not a crash.
4. **The mic cannot run in the XCTest process** (TCC grants belong to the signed bundle, DECISIONS). Real-mic tests go through S7's `runCapture`. Logic that needs no mic (conversion, stall, restart) runs in-process through the `Start` seam.
5. **Notification routing.** The engine posts `AVAudioEngineConfigurationChange` with `object: engine`. `MicSource` observes with `object: nil`: the process holds one `AVAudioEngine`, and a test-posted notification has no engine to name. Posting does not stop a real engine (OTHER.md), so the restart counter, not "chunks keep coming", is the assertion.
6. **Locking rule.** `engine.stop()` waits for an in-flight tap callback, and the callback takes the state lock. So start/stop never run under that lock: begin, restart and end run on one serial `DispatchQueue`; the lock guards only short state touched by the tap callback.
7. **Stall guard is S7's `StallGuard`.** `deliver` and a successful restart `beat()`; a task `watch()`es and ends the stream with `Stalled` (its message names the limit). The 1 s default lives in `StallGuard.limit`. `ContinuousClock` counts Mac sleep, so after wake the guard fails the stream unless a restart already re-armed it; either outcome meets the gate ("correct lines or a visible failure").
8. **Bound device is verified, not assumed.** `engineStart` reads the unit's `CurrentDevice` back and throws `MicError.notBuiltIn(name)` unless its transport is `kAudioDeviceTransportTypeBuiltIn`; the test re-derives the transport from the reported device id with its own CoreAudio call. "Regardless of default input" is falsifiable only when the default input is not the built-in mic, so the AirPods human gate carries it; no automated mutant ("skip selection") can go red on a built-in default. Stated, not hidden.
9. **Lock check.** S6 probe: `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` is `1` while locked; the unlocked form was never observed, so `requireUnlocked()` throws only when the value is `true`. A locked screen would otherwise show as an all-zero mic (DECISIONS), which test 6's non-zero check reports.
10. **APIs.** `AVAudioEngine`, `inputNode`, `installTap(onBus:bufferSize:format:block:)`, `removeTap(onBus:)`, `AVAudioConverter.convert(to:error:withInputFrom:)`, `.AVAudioEngineConfigurationChange`, `floatChannelData`: used by the spike or the converter probe. No FluidAudio call. `Chunk`, `SourceID`, `AudioSource` are the repo's.
11. **OTHER.md.** "S8: assert a restart count for the configuration-change test" resolved by tests 3 (in-process) and 7 (real engine). Parent: delete that item.
12. **Settled at build.** (a) The unlocked form of the lock key. (b) Test 6's tolerance (±4096 samples = one chunk, STRATA "±1 chunk") against real engine start-up jitter: if the first run exceeds it, record the value in `mic.md` and stop for the parent; do not widen. (c) Whether `AVAudioEngine().inputNode` alone nudges AirPods before the device is selected: only the human gate sees it. (d) The first-buffer delay after engine start: a delay over 1 s would be a false stall, seen as `ended != []`; stop and report, do not widen. (e) `noBuiltInMic` has no automated test (needs a clamshell): it is one throwing guard, covered only by hand with the lid closed.

# Blueprint

New: `Sources/TECore/MicSource.swift`, `Tests/TECoreTests/MicTests.swift`. Edited: `Sources/TEUI/VerifyCapture.swift`, `Tests/TECoreTests/{AppHarness,CaptureSupport}.swift`. Nothing else.

## `Sources/TECore/MicSource.swift`
```swift
import AVFoundation
import CoreAudio
import os

public enum MicError: Error, CustomStringConvertible {
    case noBuiltInMic, select(OSStatus), notBuiltIn(String), unsupportedFormat(String)
    public var description: String {
        switch self {
        case .noBuiltInMic: "no built-in microphone (lid closed?)"
        case .select(let s): "selecting the built-in microphone failed: \(s)"
        case .notBuiltIn(let n): "the input is bound to \(n), not the built-in microphone"
        case .unsupportedFormat(let f): "cannot convert microphone format \(f)"
        }
    }
}

public struct BoundDevice: Codable, Sendable, Equatable {
    public let id: UInt32, name: String
    public init(id: UInt32, name: String) { self.id = id; self.name = name }
}

public final class MicSource: AudioSource {
    public struct Capture: Sendable {
        public let device: BoundDevice
        public let stop: @Sendable () -> Void
        public init(device: BoundDevice, stop: @escaping @Sendable () -> Void) { self.device = device; self.stop = stop }
    }
    /// Starts capture on the built-in mic; calls `onBuffer` from the audio thread for every buffer. The seam in-process tests replace.
    public typealias Start = @Sendable (@escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> Capture

    public let id: SourceID, tag = "Mic"
    public var device: BoundDevice? { state.withLock { $0.capture?.device } }
    public var restarts: Int { state.withLock { $0.restarts } }

    private struct State {
        var continuation: AsyncThrowingStream<Chunk, Error>.Continuation?
        var capture: Capture?
        var converter: (format: AVAudioFormat, converter: AVAudioConverter)?
        var emitted = 0, restarts = 0
        var observer: NSObjectProtocol?
        var watcher: Task<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let control = DispatchQueue(label: "mic.control")  // serial: every start/stop of capture runs here, never under `state`
    private let stall = StallGuard()
    private let start: Start

    public init(id: SourceID, start: @escaping Start = MicSource.engineStart) { self.id = id; self.start = start }

    /// Called once per source: a second call is a programmer error.
    public func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            state.withLock { precondition($0.continuation == nil, "chunks() called twice"); $0.continuation = c }
            c.onTermination = { [self] _ in control.async { end(nil) } }
            control.async { [self] in
                do { try begin() } catch { end(error) }
            }
        }
    }
    public func stop() { control.async { [self] in end(nil) } }

    private func begin() throws {  // control queue
        let capture = try start { [self] in deliver($0) }
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [self] _ in
            control.async { restart() }
        }
        let watcher = Task { [self] in
            do { try await stall.watch() } catch { control.async { end(error) } }  // `watch` beats at its start: begin re-arms the guard
        }
        state.withLock { $0.capture = capture; $0.observer = observer; $0.watcher = watcher }
    }

    /// Control queue. The device is looked up fresh by `start` every time (an AirPods connect or a closed lid changes the answer).
    private func restart() {
        guard let old = state.withLock({ $0.continuation == nil ? nil : $0.capture }) else { return }  // ended: ignore
        old.stop()
        do {
            let capture = try start { [self] in deliver($0) }
            state.withLock { $0.capture = capture; $0.converter = nil; $0.restarts += 1 }  // the input format can change; resampler history across the gap is stale
            stall.beat()
        } catch { end(error) }
    }

    /// Control queue; idempotent because the first call nils the continuation.
    private func end(_ error: Error?) {
        let s = state.withLock { s -> State in defer { s.continuation = nil; s.capture = nil; s.observer = nil; s.watcher = nil }; return s }
        guard let c = s.continuation else { return }
        s.watcher?.cancel()
        s.observer.map(NotificationCenter.default.removeObserver)
        s.capture?.stop()
        c.finish(throwing: error)
    }

    /// Audio thread. Converts and yields under the lock; never calls `end` directly.
    private func deliver(_ buf: AVAudioPCMBuffer) {
        stall.beat()
        let failure: Error? = state.withLock { s in
            guard let c = s.continuation else { return nil }
            if s.converter?.format != buf.format {
                guard let conv = AVAudioConverter(from: buf.format, to: Self.target) else { return MicError.unsupportedFormat("\(buf.format)") }
                s.converter = (buf.format, conv)
            }
            let cap = AVAudioFrameCount((Double(buf.frameLength) * Double(Chunk.sampleRate) / buf.format.sampleRate).rounded(.up)) + 1  // +1: uncertainty 1
            let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: cap)!
            var fed = false, error: NSError?
            let status = s.converter!.converter.convert(to: out, error: &error) { _, flag in
                if fed { flag.pointee = .noDataNow; return nil }
                fed = true; flag.pointee = .haveData; return buf
            }
            if status == .error { return error! }
            c.yield(Chunk(samples: Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))), index: s.emitted))
            s.emitted += Int(out.frameLength)
            return nil
        }
        if let failure { control.async { [self] in end(failure) } }
    }
    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Chunk.sampleRate), channels: 1, interleaved: false)!
```
Real device code (the spike's, failures thrown):
```swift
    public static let engineStart: Start = { onBuffer in
        guard let device = builtInInput() else { throw MicError.noBuiltInMic }
        let engine = AVAudioEngine(), input = engine.inputNode
        var d = device
        let status = AudioUnitSetProperty(input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw MicError.select(status) }
        var bound = AudioDeviceID(0), n = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(input.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &bound, &n)
        let name = coreAudio(bound, kAudioObjectPropertyName, "" as CFString) as String? ?? ""
        guard coreAudio(bound, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn else { throw MicError.notBuiltIn(name) }
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buf, _ in onBuffer(buf) }
        try engine.start()
        return Capture(device: BoundDevice(id: bound, name: name), stop: { engine.stop(); input.removeTap(onBus: 0) })
    }
    /// The built-in input device, if any. nil = clamshell.
    static func builtInInput() -> AudioDeviceID? { /* the spike's builtInMic with `nil` instead of `found!`: all devices; first with a built-in transport and ≥ 1 input stream */ }
}

/// One global-scope property read; nil when the read fails.
private func coreAudio<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T?
```
The builder simplifies the `coreAudio` call sites to whatever type-checks (`CFString` as in the spike's `prop`); semantics are fixed: name from `kAudioObjectPropertyName`, transport from `kAudioDevicePropertyTransportType`, a failed transport read ⇒ not built-in. No voice processing anywhere.

## `Sources/TEUI/VerifyCapture.swift` (edit: S7's file)
- `CaptureSpec.Src` gains `case mic(id: String)` and its decode arm `case "mic": self = .mic(id: try c.decode(String.self, forKey: .id))` — JSON `{"id":"mic","kind":"mic"}`.
- `CaptureSpec` gains `let reconfigureAt: [Double]?` — seconds after `ready` at which the op posts `NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)`.
- `build()` becomes `func build() -> (sources: [any AudioSource], mic: MicSource?)`; the loop's exhaustive switch gains `.mic(let id)`: `let m = MicSource(id: SourceID(rawValue: id)); mic = m; sources.append(m)`. The op reads the tuple.
- The report gains `private struct MicReport: Encodable { let restarts: Int, device: BoundDevice?, defaultInput: String? }` and `CaptureReport.mic: MicReport?`.
- In `capture(_:)`: after the `started` wait, `device = mic?.device`, `defaultInput = AVCaptureDevice.default(for: .audio)?.localizedName` (`import AVFoundation`); after `ready` is written and before the wait group: `for t in (spec.reconfigureAt ?? []).sorted() { try await ContinuousClock().sleep(until: readyAt + .seconds(t)); post }` (`readyAt = .now` taken right after writing `ready`); before `detach`: `mic.map { MicReport(restarts: $0.restarts, device: device, defaultInput: defaultInput) }`. The device is read after `ready` because it is only meaningful while running.

## `Tests/TECoreTests/AppHarness.swift` (edit: add)
```swift
struct ScreenLocked: Error, CustomStringConvertible { var description: String { "the screen is locked: a locked session gives the mic exact zeros. Unlock the Mac and rerun ./test.sh Mic" } }
extension AppHarness {
    static func requireUnlocked() throws {
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { throw ScreenLocked() }
    }
}
```

## `Tests/TECoreTests/CaptureSupport.swift` (edit)
`Report` gains `struct MicInfo: Decodable { let restarts: Int; let device: BoundDevice?; let defaultInput: String? }` and `let mic: MicInfo?`. `let micSource: [String: Any] = ["id": "mic", "kind": "mic"]`. (`runCapture`'s `extra:` already carries `reconfigureAt`.)

## `Tests/TECoreTests/MicTests.swift` (class `MicTests`, category Mic)
Support (this file). `FakeMic: @unchecked Sendable` with a lock: `start` (a `MicSource.Start`) records the call (`starts`), stores `onBuffer`, returns `Capture(device: BoundDevice(id: 7, name: "fake"), stop: { stops += 1 })`; throws `FakeError.boom` on a configured call number. `emit(rate: R, count: n, from: k)` builds n mono Float32 buffers of 4096 frames at rate R, sample *i* of the run = `0.5·sin(2π·1000·i/R)` (phase continues across buffers; `from` is the first sample number), and calls the stored `onBuffer`. `source(fake) = MicSource(id: SourceID(rawValue: "mic"), start: fake.start)`. `within(seconds: 5, _ what:, body)` races the body against `Task.sleep` and fails with "timed out: <what>" (hang detector for no-guard mutants; 5 s > 4× the longest legitimate wait here). `zeroCrossings([Float])`.

**In-process (no mic, no app, any host):**
1. `testBuffersBecome16kMonoOnTheSampleClock`. Fake emits 50 buffers at 48 kHz, then `source.stop()`; collect. Assert indices contiguous (`chunk[k].index == Σ previous counts`); total within 16 of 68,266.7 (uncertainty 1); RMS within 2% of `0.5/√2`; zero crossings within 2% of `2·total·1000/16000`; `source.tag == "Mic"`. Repeat at 44.1 kHz (expected 74,303.9). Mutants: yield raw 4096 samples ⇒ count red; target rate 8000 ⇒ count and crossings red; converter built per buffer ⇒ crossings fail at the seams.
2. `testStreamFailsWhenBuffersStopForOverOneSecond`. `requireIdleMachine()`. 3 buffers 100 ms apart, then nothing: `within` collect throws `StallGuard.Stalled`; elapsed from the last emit ∈ [1.0 s, 2.0 s] (1.0 = the limit; 2.0 = twice it, so a slower guard is red). Control, same test: a buffer every 500 ms for 3 s ⇒ no throw; `stop()` ends the stream with no error. Mutants: no `watch` ⇒ `within` times out; limit 3 s ⇒ upper bound red; limit 0.25 s ⇒ control red.
3. `testConfigurationChangeRestartsOnceAndChunksResumeContiguously`. Emit 5 buffers at 48 kHz; post the notification; `within` until `fake.starts == 2`; emit 5 at 44.1 kHz; `stop()`. Assert `restarts == 1`, `fake.stops == 2`, indices contiguous across the restart, the second half's count within 16 of 7,430.4 (the converter followed the new format), no error. Mutants: no observer ⇒ `starts` never 2 ⇒ `within` red; converter kept across the format change ⇒ count red; restart resets `emitted` ⇒ contiguity red; restart does not stop the old capture ⇒ `stops` red.
4. `testStallGuardIsRearmedByARestart`. `requireIdleMachine()`. Emit one buffer; wait 0.6 s; post; wait until `starts == 2`; emit nothing. Collect throws `Stalled` with elapsed from `starts == 2` ∈ [0.9 s, 2.0 s]. Mutant: restart does not `beat()` ⇒ fires ~0.4 s after the restart ⇒ red.
5. `testARestartThatFailsFailsTheStream`. Fake throws `boom` on call 2. Emit one buffer; post; collect throws `FakeError.boom`. Mutant: swallow the error in `restart()` ⇒ `within` times out.

**Real engine (via `runCapture` and the installed app).** Every test starts with `try AppHarness.requireUnlocked()` and sets `executionTimeAllowance` to its run length + 120 s.
6. **`testRealMicTenSecondsAdvancesWithWallClockAndIsNotSilent`.** `cap = runCapture(self, [micSource]) { sleep 10 }`; `s = cap.samples["mic"]!`, `a = report.sources["mic"]!.arrivals`. Assert `ended == []`; `report.mic!.restarts == 0`; `s.count == a.last.end`; `maxClockDrift(a) ≤ 4096/16000` (STRATA ±1 chunk); `a.last.wall − a.first.wall ≥ 9`; `s.contains { $0 != 0 }` and `s.map(abs).max()! > 0` (message: a locked or denied mic gives exact zeros); the test reads the transport type of `report.mic!.device!.id` with its own `AudioObjectGetPropertyData(kAudioDevicePropertyTransportType)` and expects `kAudioDeviceTransportTypeBuiltIn`; `cap.report.lines.allSatisfy { $0.tag == "Mic" }`. Writes `resultsDir()/mic.md`: device name, `defaultInput`, arrival count, largest arrival gap (the 107 ms figure re-measured), peak, RMS, nonzero fraction. Mutants: converter outputs zeros ⇒ nonzero red; target rate wrong ⇒ wall assertion red; `restarts` incremented on begin ⇒ red; skip device selection ⇒ red only off a built-in default (uncertainty 8).
7. **`testRealConfigurationChangeRestartsOnceAndAudioResumes`.** `runCapture(self, [micSource], extra: ["reconfigureAt": [4.0]]) { sleep 10 }`. Assert `ended == []`; `mic.restarts == 1`; `s.count == a.last.end`; at least 20 arrivals with `wall > a.first.wall + 4.5` (≈ 12 chunks/s × 5 s = 60 expected; 20 is a third, tolerant of a slow restart but not of none); `s` contains non-zero. Record the observed count in `mic.md`. Mutants: observer removed ⇒ `restarts == 0` red; restart stops but does not start ⇒ `ended` holds a stall ⇒ red; no re-arm ⇒ stall ⇒ red.
8. **`testQuickTimeRmsIsUnchangedByTheMicAndTagsStayApart`.** Inside `AppHarness.muted`. Clip = `turnWav(3)` (11.9 s, ≈ 20 s per run instead of 100 s; a ducking mic still shows). Three runs, each `QuickTime.open(clip)`; `runCapture { play; sleep 11.9 + captureTail }`; `QuickTime.quit()`: `b1` = `[qt]` alone, `b2` = `[qt]` alone, `m` = `[qt, micSource]`. `r(x) = speechRMS(x.samples["qt"]!)`. Assert `|r(b1) − r(b2)|/r(b1) ≤ 0.01` first (stable measurement; repeats measured 0.3%), then `|r(m) − r(b1)|/r(b1) ≤ 0.01` (STRATA). In `m`: `ended == []`; `lines` with `src == "qt"` non-empty and all `tag == "QuickTime"`; `lines` with `src == "mic"` all `tag == "Mic"`. This is why voice processing was rejected (it ducked other apps ~8 dB). Mutants: `input.setVoiceProcessingEnabled(true)` in `engineStart` ⇒ ducking ⇒ RMS red; `Src.app` build ignoring `tag` ⇒ tag assertion red.

Each mutant: one edit, the single named test red, revert, green. In-process mutants (1–5) run on any host; real ones (6–8) run on mac-work-2 with the screen unlocked.

## Attaining the human-verifiable result (required gate)
1. `./build.sh`. Unlock the Mac, connect AirPods and make them the default input.
2. Scenario and run (stop after 180 s):
```
S=$(mktemp -d)
printf '{"root":"%s","steps":[{"op":"capture","sources":[{"id":"mic","kind":"mic"}]}]}' "$S" > "$S/s.json"
(sleep 180; touch "$S/stop") & open -W -n --stdout "$S/out" --stderr "$S/err" ~/Applications/TranscribeEverything.app --args verify "$S/s.json"
```
3. Minh, in order: read a sentence aloud (about 20 s in); disconnect and reconnect AirPods (about 60–90 s); sleep and wake the Mac (about 120–150 s). AirPods audio must stay normal quality (no hands-free "phone" sound).
4. `cat "$S"/transcripts/*.jsonl "$S/s.report.json"`. Pass = `[Mic]` lines with the sentence, and any gap explained by `ended[].error` (after sleep: a stall is expected) or `mic.restarts > 0`; AirPods stay in normal mode. Neither lines nor a reason is a defect.
5. Record device name, `restarts`, `ended`, lines in DECISIONS.

## Order of work
`MicSource.swift` ⇒ `MicTests` 1–5, `./test.sh Mic` green ⇒ `VerifyCapture` + `AppHarness` + `CaptureSupport` edits ⇒ tests 6–7 on mac-work-2 (unlocked) ⇒ test 8 ⇒ mutants ⇒ human gate ⇒ fresh adversarial review.

## Not in S8
Menu, `Microphone` checkmark, failure display (S9–S12); device-change policy beyond "restart on notification, look up the built-in again each time".

# Build findings (supersede the sections above)
- Selecting the device posts a configuration change before audio flows, so restarting on every notification looped forever. `restart()` acts only after the current capture delivered a buffer. `AVAudioEngine.isRunning` cannot decide this: it stays true after a real rate change. New in-process test: a notification before the first buffer does not restart.
- Real test 7 stays as blueprinted (posts the notification). Traced: flipping the mic's nominal rate posts no notification; audio stops and the stall guard ends the source with its reason.
- Real-mic tests 6 and 7 skip with the reason when the screen is locked. Test 8 runs locked: ducking does not depend on what the mic hears.
- Test 8 bounds both comparisons at 3%: identical runs measured 1.14% apart, voice processing 54%.
- A restart cancels the stall watcher and starts a new one from the new capture: at load 20 a real restart exceeded 1 s.
- Human gate pending: Minh's AirPods, lid and sleep checks.
