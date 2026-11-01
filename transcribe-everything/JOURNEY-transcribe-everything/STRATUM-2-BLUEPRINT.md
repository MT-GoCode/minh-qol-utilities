# Stratum 2 Blueprint — Segmentation: VAD pipeline to committed JSONL

Builds on `STRATUM-1-BLUEPRINT.md` (ground truth: `Paths`, `Config`/`ConfigStore`, `Line`, `TranscriptStore`, `AudioSource`/`Chunk`, `FileSource`, `Transcriber`, test `Support`, `Fixtures`, `./test.sh`). Nothing in S1 is edited.

# Uncertainties squashed

FluidAudio paths are under `~/general-purpose/conversation-contexts/transcribe-everything/vendor-src/FluidAudio/Sources/FluidAudio` (v0.18.0).

1. **VAD API, all public.** `VadManager()` async init (`VAD/VadManager.swift:79`, an `actor`); `processStreamingChunk(_:state:config:returnSeconds:timeResolution:) async throws -> VadStreamResult` (`VadManager+Streaming.swift:11`); `VadStreamResult.{state,event,probability}` (`VadTypes.swift:209`); `VadStreamEvent.{sampleIndex,isStart,isEnd}` (`:189-207`); `VadStreamState.initial()` (`:184`, public static, so no actor hop is needed to make a state; `VadManager.makeStreamState()` is actor-isolated and is not used); `VadSegmentationConfig(minSilenceDuration:)` (`:37`, other fields default); `VadManager.chunkSize` = 4096 and `sampleRate` = 16000 (`VadManager.swift:22,26`). `VadManager` holds no per-stream state: the caller threads `VadStreamState`, so one `VadManager` is shared by every pipeline and each pipeline owns its state.
2. **Event indices.** Start: `sampleIndex = max(0, processed − speechPadding(0.1 s = 1600) − chunk)` = chunk start − 1600 (`VadManager+Streaming.swift:57-59`). End: `silenceStart + 1600 − chunk` with `silenceStart` = end of the first quiet chunk (`:70-75`), so it can fall before a force-cut point and before `start` (hence `max(e.sampleIndex, start + 1)`, as in `Bench cut`). The start index is always inside the previous chunk's final 1600 samples, so keeping the last 2 chunks while idle (`2 * chunkSize` = 8192 ≥ 4096 + 1600) always holds the segment start. End index ≤ processed.
3. **Short tail chunk.** `FileSource` ends with a chunk of 1…4096 samples. `Bench cut` loops `while i + chunkSize <= count`, so the tail never reaches the VAD but is part of the flush. The pipeline does the same (tail appended to the buffer, not sent to the VAD). This is the measured behaviour.
4. **Measured segmenter** (`spike/Sources/Bench/main.swift` case `"cut"`, lines 172-214; results `cut-conversation.json`, `cut-continuous.json`): conversation 14 lines, 2 `cut`, 12 `end`, lines (start,end) listed there; continuous 5 lines, 4 `cut`, 1 `flush`, longest 11.3 s, 2/159 errors. The port keeps every operation of that loop in the same order.
5. **Line length bound.** A cut fires on the first chunk whose end `i` has `i − start ≥ 12 s`; the previous chunk had `< 12 s`, and the cut point is ≤ `i`. So a line is `< 12 s + 4096/16000 = 12.256 s`. STRATA's "every line ≤ 12 s" is therefore not guaranteed by construction (measured longest 11.3 s). The test asserts `≤ maxSegment + 4096/16000` (derived, not measured). **Flag to parent: STRATA wording is off by one chunk.**
6. **Per-turn word bound, measured (`Bench cut` lines vs `scratch/turn*.json` oracle, truth `fixtures/conversation.json`; lines grouped to a turn by midpoint inside `[turn.start, turn.end]`).** Lines per turn: 1 each, except turns 9 and 11 with 2. Errors ours/oracle per turn: 0/0 0/0 0/0 0/0 0/0 **1/0** 0/0 1/1 0/0 2/2 1/1 1/2 = 6/6. Turn 5 is +1 with no cut: the VAD start (33.18 s) is not the clip start (32.815 s), so Ultra sees different framing. STRATA's "oracle + 1 word per cut" is violated by turn 5, so per-turn bound is `oracle + lines in the turn` (1 for framing + 1 per cut) and the corpus bound is `Σ oracle + cuts`. **Flag to parent.**
7. **Boundary offsets vs oracle word times, measured (same data).** First line start − (turn.start + first oracle word start): −0.31…+0.23. Last line end − (turn.start + last oracle word end): −0.26…+0.42. Bound ±0.5 s (DECISIONS). Oracle JSON keys: `wordTimings[].{word,startTime,endTime,confidence}`, times relative to the clip (`scratch/turn00.json`, FluidAudioCLI `TranscribeCommand.swift:100-104`). "Each boundary" is read as the turn boundaries (first start, last end), the quantity DECISIONS measured; cut points inside a turn have no oracle.
8. **Streams buffer.** `AsyncThrowingStream` default buffering is unbounded and delivers buffered elements before a `finish()`. So `detach` (→ `stop()` → `finish()`) still processes already-yielded chunks, then ends the loop and flushes.
9. **Deferred (not in this stratum, add to OTHER.md):** (a) a force-cut can land on a quiet chunk just before the VAD end event; the end index then precedes the cut, `max(e, start+1)` yields a 1-sample segment, padded to 0.3 s, which decodes to an empty-text `Line`. Not seen in the 5 measured cuts. Revisit with S3 (word runs make empty lines representable); (b) reading `Config` per segment open is implemented, its change test is S14's.
10. **Public FluidAudio calls beyond S1:** none other than the VAD ones in (1). `Transcriber.transcribe(_:) -> ASRResult` (S1) is the only decode path.

# Blueprint

## Files

```
Sources/TECore/SpeakerTracker.swift     (new)
Sources/TECore/SourcePipeline.swift     (new)
Sources/TECore/Engine.swift             (new)
Tests/TECoreTests/PipelineSupport.swift (new, test helpers only)
Tests/TECoreTests/PipelineTests.swift   (new, category Pipeline)
```
No existing file is edited. `test.sh` already runs any new XCTest class.

### `SpeakerTracker.swift`
```swift
public protocol SpeakerTracker: Sendable { func assign(window: [Float]) async -> Int }
public struct SingleSpeaker: SpeakerTracker {
    public init() {}
    public func assign(window: [Float]) async -> Int { 1 }
}
```
S3 replaces `SingleSpeaker` wholesale; the protocol is the interface STRATA names.

### `SourcePipeline.swift`
```swift
import FluidAudio
import Foundation

struct SourcePipeline: Sendable {
    let source: any AudioSource
    let vad: VadManager
    let transcriber: Transcriber
    let store: TranscriptStore
    let config: ConfigStore
    let tracker: any SpeakerTracker

    private struct Open { var start: Int; var probs: [(end: Int, p: Float)] = [] }   // probs exist only while a segment is open

    /// Returns when the source finishes; rethrows its failure after committing the open segment.
    func run() async throws {
        let sr = Chunk.sampleRate, chunk = VadManager.chunkSize
        var base = 0, samples: [Float] = []       // samples[0] is source sample `base`
        var state = VadStreamState.initial()
        var cfg = await config.current
        var open: Open? = nil

        func commit(_ s: Int, _ e: Int) async throws {
            let seg = Array(samples[(s - base)..<(e - base)])
            let text = try await transcriber.transcribe(seg).text
            try await store.append(Line(t: Date(), src: source.id, tag: source.tag, spk: await tracker.assign(window: seg),
                                        text: text, start: Double(s) / Double(sr), end: Double(e) / Double(sr)))
        }
        func flush() async throws {
            guard let o = open else { return }
            try await commit(o.start, base + samples.count)
            open = nil
        }

        do {
            for try await c in source.chunks() {
                precondition(c.index == base + samples.count, "source chunks must be contiguous")
                samples += c.samples
                let end = base + samples.count
                if c.samples.count == chunk {                                  // the short tail chunk only reaches the flush
                    let r = try await vad.processStreamingChunk(
                        c.samples, state: state, config: VadSegmentationConfig(minSilenceDuration: cfg.minSilence))
                    state = r.state
                    if let e = r.event, e.isStart { open = Open(start: e.sampleIndex); cfg = await config.current }
                    open?.probs.append((end, r.probability))
                    if let e = r.event, e.isEnd, let o = open {
                        try await commit(o.start, max(e.sampleIndex, o.start + 1))
                        open = nil
                    } else if let o = open, end - o.start >= Int(cfg.maxSegment * Double(sr)) {
                        let cut = o.probs.filter { $0.end >= end - 2 * sr }.min { $0.p < $1.p }!.end   // lowest-probability chunk of the last 2 s
                        try await commit(o.start, cut)
                        open = Open(start: cut, probs: o.probs.filter { $0.end > cut })
                        cfg = await config.current
                    }
                }
                let drop = max(0, (open?.start ?? end - 2 * chunk) - base)    // idle: keep 2 chunks (Uncertainty 2)
                samples.removeFirst(drop); base += drop
            }
        } catch {
            try await flush()
            throw error
        }
        try await flush()
    }
}
```
Constants: `2 * sr` = "last 2 s" (DECISIONS, Segmentation); `2 * chunk` = Uncertainty 2; `minSilence` and `maxSegment` come from `Config` (0.5 and 12, DECISIONS). `precondition` on contiguity is a guard that blows up: a gapped source (S7/S8 stall) must fail in the source, never silently shift timestamps. The VAD config passed per call uses `cfg.minSilence` (state machine reads it per call), refreshed at each segment open (start event or cut), as STRATA requires.

### `Engine.swift`
```swift
import FluidAudio

public struct SourceEnd: Sendable { public let id: SourceID; public let error: Error? }   // nil = finished

public actor Engine {
    public nonisolated let ended: AsyncStream<SourceEnd>
    private let endedContinuation: AsyncStream<SourceEnd>.Continuation
    private let transcriber: Transcriber, vad: VadManager, store: TranscriptStore, config: ConfigStore
    private var running: [SourceID: (source: any AudioSource, task: Task<Void, Never>)] = [:]

    public init(transcriber: Transcriber, vad: VadManager, store: TranscriptStore, config: ConfigStore) {
        (ended, endedContinuation) = AsyncStream.makeStream(of: SourceEnd.self)
        self.transcriber = transcriber; self.vad = vad; self.store = store; self.config = config
    }

    public func attach(_ source: any AudioSource) {
        precondition(running[source.id] == nil, "source already attached")
        let pipeline = SourcePipeline(source: source, vad: vad, transcriber: transcriber, store: store,
                                      config: config, tracker: SingleSpeaker())
        running[source.id] = (source, Task {
            let error: Error?
            do { try await pipeline.run(); error = nil } catch let e { error = e }
            self.finish(SourceEnd(id: source.id, error: error))
        })
    }

    /// Stops the source, waits for its open segment to commit.
    public func detach(_ id: SourceID) async {
        guard let r = running[id] else { return }
        r.source.stop()
        await r.task.value
    }

    private func finish(_ end: SourceEnd) { running[end.id] = nil; endedContinuation.yield(end) }
}
```
`finish` is actor-isolated; calling it from the unstructured `Task` needs `await` (`await self.finish(...)`); write it so. `detach` of an id that already ended is a no-op. Re-attaching an id after its `SourceEnd` is allowed. The ended stream is never finished (the engine lives for the app's life); consumers take what they need.

## Tests

Category `Pipeline` (class `PipelineTests`). All real: real Silero VAD, real Ultra, real fixtures; no mocks except the test-defined `FailingSource`. `import XCTest, AVFoundation, FluidAudio, TECore` (`@testable` never).

### `PipelineSupport.swift`
```swift
enum Models {                                          // loaded once per test process
    static let transcriber = Task { try await Transcriber.load() }
    static let vad = Task { try await VadManager() }
}
extension Fixtures {                                   // S1's enum; additive
    static var conversationWav: URL { dir.appending(path: "conversation.wav") }
    static var continuousWav: URL { dir.appending(path: "continuous.wav") }
    static func continuousText() throws -> String      // JSONSerialization of continuous.json ["text"]
    static func oracleWords(_ i: Int) throws -> [(start: Double, end: Double)]   // oracle/%02d.json wordTimings[].startTime/endTime
}
struct Seg: Equatable { let start, end: Double; let text: String }      // a Line without t
func segs(_ lines: [Line], src: String) -> [Seg]                         // lines with that src, in order
func tempRoot(_ test: XCTestCase) -> URL                                  // te-UUID dir, removed via addTeardownBlock
func makeEngine(_ root: URL) async throws -> (Engine, TranscriptStore)    // Paths(root:), TranscriptStore, ConfigStore(), shared models
func awaitEnds(_ engine: Engine, _ n: Int) async -> [SourceEnd]           // first n elements of engine.ended
func runToEnd(_ sources: [any AudioSource], _ root: URL) async throws -> (lines: [Line], ends: [SourceEnd], file: URL)
    // makeEngine, attach all, awaitEnds(count), (await store.snapshot(), ends, store.file)
func truncated(_ url: URL, frames: Int, in dir: URL) throws -> URL
    // AVAudioFile read first `frames` frames of processingFormat into a buffer, write to dir/"trunc.wav" with inf.fileFormat.settings; the output file is released (flushed) before returning
struct Boom: Error {}
struct FailingSource: AudioSource {                  // forwards `base`, throws Boom() when it reaches a chunk with index >= failAt
    let base: FileSource, failAt: Int
    var id: SourceID { base.id }; var tag: String { base.tag }
    func chunks() -> AsyncThrowingStream<Chunk, Error> { ... Task over base.chunks(); onTermination cancels it ... }
    func stop() { base.stop() }
}
```
`wer`/`normalize`/`resultsDir`/`collect` from S1 `Support.swift`.

### `PipelineTests`
Shared: `let conv = FileSource(url: Fixtures.conversationWav, id: SourceID(rawValue: "conv"), tag: "conv")`, `cont` likewise with `continuousWav`/`"cont"`. `cuts(lines)` = `zip(lines, lines.dropFirst()).filter { $1.start == $0.end }.count` (a cut makes the next segment start at the cut sample; ends never do). `SR = 16000`.

1. **`testConversationBecomesFourteenLinesMappedToTheTwelveTurns`**
   Setup: `runToEnd([conv], tmp)`; `turns = Fixtures.turns()`.
   Asserts:
   - `ends` is one element with `error == nil`; every line has `src == "conv"`, `tag == "conv"`, `spk == 1`; `lines.count == 14`; `cuts(lines) == 2` (`Bench cut`).
   - Group lines by the turn whose `[start, end]` contains the line midpoint; every line lands in exactly one turn and every turn gets ≥ 1 line.
   - Per turn `i`: `e_i = wer(ref: turns[i].text, hyp: group.map(\.text).joined(separator: " ")).errors`, `o_i = wer(ref: turns[i].text, hyp: Fixtures.oracleText(i)).errors`; assert `e_i <= o_i + group.count` (Uncertainty 6). Corpus: `Σe_i <= Σo_i + 2` (the 2 cuts).
   - Boundaries: `w = oracleWords(i)`; `abs(group.first.start − (turns[i].start + w.first.start)) <= 0.5` and `abs(group.last.end − (turns[i].start + w.last.end)) <= 0.5`.
   - Human artefact: copy `file` to `resultsDir()/pipeline-conversation.jsonl`; write `resultsDir()/pipeline.md`: table `| turn | lines | start–end | errors (ours/oracle) | text |` per turn plus a corpus row.
   Mutations: set the VAD `minSilenceDuration` constant to 0.25 ⇒ 16 lines ⇒ count red; delete the `else if` cut branch ⇒ `cuts == 0` and `lines.count == 12` ⇒ red; swap `start`/`end` in the `Line` ⇒ boundary red; hard-code `max(e.sampleIndex, o.start + 1)` to `o.start + 1` ⇒ every line 1 sample ⇒ text red.
2. **`testContinuousSpeechIsForceCutAndLosesNoWords`**
   Setup: `runToEnd([cont], tmp)`; whole = `await Models.transcriber.value.transcribe(collect(FileSource(url: Fixtures.continuousWav, id: …, tag: …)).flatMap(\.samples)).text` (the whole-file decode `Bench cut` used as baseline).
   Asserts: `lines.count == 5` and `cuts(lines) == 4` (`cut-continuous.json`); every `line.end − line.start <= 12.0 + 4096.0/16000` (Uncertainty 5); `(e, w) = wer(ref: Fixtures.continuousText(), hyp: joined lines)`; `w == 159`; `e <= wer(ref:, hyp: whole).errors + 4`; lines are contiguous or gapped but strictly increasing (`lines[k].start >= lines[k−1].end`).
   Mutations: remove the force-cut branch ⇒ one 52.9 s line ⇒ count and length red.
3. **`testStreamEndingMidSpeechCommitsTheOpenSegment`**
   Setup: `n = Int((turns.last!.end − 1.0) * 16000)`, `trunc = truncated(Fixtures.conversationWav, frames: n, in: tmp)`; `runToEnd([FileSource(url: trunc, …)], tmp)`.
   Asserts: `error == nil`; `lines.count == 14` (the 13 earlier lines plus the flushed remainder of the last turn); `lines.last.end == Double(n)/16000` exactly; `lines.last.start >= turns.last!.start − 0.5`; `!lines.last.text.isEmpty`.
   Mutations: delete the final `try await flush()` ⇒ last line missing ⇒ red.
4. **`testTwoSourcesOnOneEngineKeepTheirOwnLines`**
   Setup: solo runs `a = segs(runToEnd([conv]).lines, "conv")`, `b = segs(runToEnd([cont]).lines, "cont")` (fresh temp roots); then `runToEnd([conv2, cont2])` with fresh sources of the same ids.
   Asserts: both `SourceEnd.error == nil`; `segs(lines, "conv") == a` and `segs(lines, "cont") == b` (same start, end, text); the store file lines equal `snapshot()` in count.
   Mutations: hoist `state` out of `run()` into one value shared by all pipelines ⇒ VAD states interleave ⇒ differ ⇒ red.
5. **`testDetachCommitsTheOpenSegmentAndReportsTheEnd`**
   Setup: `makeEngine`; `paced = FileSource(url: conversationWav, id: "conv", tag: "conv", clock: ContinuousClock())`; `attach`; `try await Task.sleep(for: .seconds(1.5))`; `await engine.detach(id)`; `ends = await awaitEnds(engine, 1)`.
   Asserts: `ends[0].error == nil`, `ends[0].id == "conv"`; `snapshot()` has exactly 1 line; its `end` is in `1.0...1.9` (chunks yielded by 1.5 s end at 24576 = 1.536 s; jitter allowance one chunk); `!text.isEmpty`.
   Mutations: delete the final `flush()` ⇒ 0 lines ⇒ red; make `detach` skip `source.stop()` ⇒ the 100 s paced source keeps running and `detach` blocks; the test sets `executionTimeAllowance = 30` so this fails instead of hanging.
6. **`testSourceFailureCommitsTheOpenSegmentThenReportsTheFailure`**
   Setup: `FailingSource(base: conv, failAt: 32_000)` through `runToEnd`.
   Asserts: `ends[0].error is Boom`; `lines.count == 1`; `lines[0].end == 32_768.0/16000` (last delivered chunk is index 28672, 4096 long); `!text.isEmpty`.
   Mutations: flush only on the success path (remove the `catch` flush) ⇒ 0 lines ⇒ red.

Mutation protocol: as S1 — apply by hand, `./test.sh Pipeline`, confirm red, `git checkout -- <file>`, confirm green; the red/green pairs go in the commit message.

## Attaining the result (each a rerunnable command)

1. `./test.sh Pipeline` ⇒ green; prints `results: test-results/<ts>`.
2. `cat test-results/<ts>/pipeline-conversation.jsonl` ⇒ the conversation line by line (the committed session JSONL, 14 lines, `spk` 1, ISO-8601 `t`).
3. `cat test-results/<ts>/pipeline.md` ⇒ per-turn table with errors ours/oracle and the corpus row (6 vs 6 expected, bound 8).
4. Full `./test.sh` ⇒ S1 + S2 green together (single suite).

## Not in this stratum
Speaker embedding or `CentroidTracker` (S3), provisional tails and Transcriber priority (S4), per-engine tracker registry (S3: Engine gains it), `Config` file and live-change test (S14), empty-text lines from sub-chunk segments (Uncertainty 9a).

# Review corrections (apply at build; these override the sections above)
- `commit` drops whitespace-only text: a cut landing in silence, a VAD blip or a silent flush tail would otherwise write a blank caption. Tests 1 and 2 assert no empty text. Mutation: remove the guard.
- The pipeline owns the VAD grid: keep `fed`, the next sample not yet sent to the VAD; after appending a chunk, loop while at least 4096 unsent samples exist. Real capture buffers are not 4096 samples. Test: a source re-chunked to 3000 samples gives the same lines. Mutation: treat each incoming chunk as one VAD chunk.
- Source-error path: keep the original error if the flush also fails.
- Truncated-conversation expected count comes from a real run, or assert the last-line checks only.

# Parent correction (overrides above)
No `SpeakerTracker` protocol and no `SingleSpeaker`: one implementation needs no protocol. S2 writes `spk: 1` directly; S3 adds `CentroidTracker` as a plain type.
