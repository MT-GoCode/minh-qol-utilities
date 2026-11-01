# Stratum 3 Blueprint — Speakers: word labels from sliding windows

Builds on `STRATUM-1-BLUEPRINT.md` and `STRATUM-2-BLUEPRINT.md` (with its "Review corrections"). Ground truth: `Transcriber`, `Config`/`ConfigStore`, `Line`, `TranscriptStore`, `FileSource`, `SourcePipeline`, `Engine`, `SpeakerTracker`, test `Support`/`PipelineSupport`.

# Uncertainties squashed

FluidAudio paths are under `~/general-purpose/conversation-contexts/transcribe-everything/vendor-src/FluidAudio` (v0.18.0). `Sources/FluidAudio` is abbreviated `FA`.

1. **Embedding API, public.** `DiarizerManager.init(config: = .default)` (`FA/Diarizer/Core/DiarizerManager.swift:25`, a non-`Sendable` `final class`, so it lives inside an actor); `initialize(models: consuming DiarizerModels)` (`:43`, synchronous); `extractSpeakerEmbedding<C>(from: C) throws -> [Float]` for `RandomAccessCollection<Float>` with `Index == Int` (`:93`), so an `[Float]` window works; the doc comment says L2-normalized, 256-d. `DiarizerModels.download()` (`DiarizerModels.swift:41`, all parameters defaulted) is what S1's `prefetch` already calls; `downloadIfNeeded()` (`:93`) only forwards to it. `DiarizerManager` is compiled under `#if Diarizer`, which `Package.swift:39` of FluidAudio defines unconditionally, and the spike's `Bench windows` (`spike/Sources/Bench/main.swift:253-282`) used the same calls.
2. **`tokenTimings` optionality settled: never nil from `Transcriber`.** The only two producers on the samples path both end in `processTranscriptionResult` (`AsrManager+Transcription.swift:25-36` for audio ≤ 15 s; `ChunkProcessor.swift:904,974` for longer), which always passes `tokenTimings: createTokenTimings(...)` (`:577,591`); that function returns `[]` on empty input (`AsrManager+TokenProcessing.swift:33-38`). So silence gives `[]`, not nil. The pipeline reads `r.tokenTimings!`: a nil would be a FluidAudio change and must crash, not degrade. No `Transcriber` signature change.
3. **Do joined words equal the decode text? Not guaranteed, so words are the source.** `text` = vocabulary pieces joined, `▁` replaced by space, whitespace-trimmed (`AsrManager.swift:565-574`). `TokenTiming.token` is the same piece with `▁` already replaced by a space (`normalizedTimingToken`, `AsrManager.swift:560`; used at `+TokenProcessing.swift:92`). `buildWordTimings` (`AsrTypes.swift:223-258`, public) starts a word at any token with a leading space and trims each word. The two agree except where a decode contains two boundary markers in a row (a double space in `text`). Decision: `Line.text` = the run's words joined by single spaces; there is one origin for text and for word labels. The S2 tests compare through `normalize`, which ignores spacing. Test 2 checks that joined words equal `result.text` exactly on the 12 conversation turns, so FluidAudio changing this would turn it red.
4. **Windows on the live path.** Port of `Bench windows` (`:253-282`): window = `Int(2.0 × 16000)` = 32000, hop = 8000; `next` starts at the VAD start event's `sampleIndex`; after each VAD chunk, `while next + win <= processed { embed; next += hop }`; the end-event chunk emits none (the spike set `open = nil` before the loop); windows keep coming through the silent tail until the end event. The pipeline does exactly that, inline in the chunk loop, so a window is embedded the moment its last sample arrives (31 ms, DECISIONS) and the label exists before the segment commits.
5. **Tracker port.** `spike/analyze_sustain.py:30-41` (thr 0.35, K = 4): embeddings unit-normalized; `sims` = cosine to each normalized running-sum centroid; if `max(sims) >= thr` the first argmax gets the window, `pend` clears, label = that centroid; otherwise the window joins `pend`, and at `len(pend) >= K` a new centroid = sum of `pend`, `pend` clears, label = the new centroid; otherwise the label stays `prev` (initially centroid 0, so the first speaker's first K−1 windows are "Speaker 1" before any centroid exists). Labels are index + 1. The port keeps this order. Doubles are used because the script used float64.
6. **Word → window rule.** The script uses the nearest window of all windows (`np.argmin(abs(mids - m))`). The pipeline restricts candidates to the windows of the segment being committed (`mid` in `[segment start, segment end)`). Proof the restriction changes nothing at segment ends: windows start at the start event, so mid₀ = start + 1 s; a word at start + δ (δ < 1 s) is 1 − δ from window 0; the previous segment's last window has mid ≤ its end − 1 s and lies at least the 0.5 s silence plus δ plus 1 s away. At a force-cut windows continue across the cut, so only words within about one hop of the cut can differ. Segments with no window of their own (shorter than about 2 s) take `tracker.previous`, as DECISIONS says. Remaining risk: the accuracy bounds were measured with the global rule; the −2 points margin covers the cut edges, and the tests are the arbiter.
7. **Line times with runs.** S2's tests need segment edges exact (`last.end == n/16000`, `cuts()` = adjacent `start == end`, boundary ±0.5 s). So: the first run's `start` = segment start, the last run's `end` = segment end, every inner edge is a word time (`last word end` / `first word start`). A speaker split therefore never makes `start == end`, so `cuts()` still counts only force-cuts.
8. **S2 assertions that S3 changes (the only ones).** In the measured conversation, a new speaker's first turn keeps the previous label for the first four windows (about 2.5 s of words), so a turn splits into two lines by design. Hence S2 test 1 `spk == 1` and `lines.count == 14` and test 2 `lines.count == 5` become "plus the speaker splits". Tests 3–6 are unchanged: test 3's count is dropped (S2 correction allows it); tests 5 and 6 hold one line each because a segment under 2.05 s holds at most one window, labeled 1.
9. **Scoring needs word times the Lines do not carry.** Instead of widening `Line`, the test re-decodes each Line's own sample span with `Transcriber` and `buildWordTimings` and labels those words with the line's `spk` (word mid = `line.start + (start+end)/2`). Execution and check share only FluidAudio. The AMI wav is already 900 s (S1 `fixtures.py` stage 3), matching `sustain_probe.sh`'s `900`.
10. **Conversation truth.** `data/ami/conversation.rttm` of the spike is not a fixture. The reference is the turns of `conversation.json` (`speaker,start,end`), the same intervals.
11. **One-to-one mapping.** `linear_sum_assignment` is replaced by a bitmask dynamic program over truth speakers (≤ 9, so ≤ 512 states); it returns the same optimum.
12. **Deferred, adds to OTHER.md:** (a) S2 Uncertainty 9a (empty line from a 1-sample segment) is now closed: `commit` returns when `words` is empty. (b) The soak (S4) must include 7,200 embeddings through the same `Embedder`. Resolved here: the S3 item "replace 'a line never holds two labels'" (test 4).

# Blueprint

## Files

```
Sources/TECore/Embedder.swift          (new)
Sources/TECore/CentroidTracker.swift   (new)
Sources/TECore/SpeakerTracker.swift    (regenerated: SingleSpeaker deleted, `previous` added)
Sources/TECore/SourcePipeline.swift    (regenerated whole)
Sources/TECore/Engine.swift            (regenerated whole)
Tests/TECoreTests/SpeakerTests.swift   (new, category Speakers)
Tests/TECoreTests/PipelineSupport.swift, PipelineTests.swift   (S2 files, amended as in "S2 amendments")
```
STRATA's file list omits the two S2 test files; the amendments below are required by Uncertainty 8.

### `Embedder.swift`
```swift
import FluidAudio

public actor Embedder {
    private let diarizer: DiarizerManager
    private init(_ diarizer: DiarizerManager) { self.diarizer = diarizer }
    public static func load() async throws -> Embedder {
        let d = DiarizerManager()
        d.initialize(models: try await DiarizerModels.download())
        return Embedder(d)
    }
    public func embed(_ window: [Float]) throws -> [Float] { try diarizer.extractSpeakerEmbedding(from: window) }
}
```
One actor serializes every source's embedding (the model is not shared-safe), like `Transcriber`.

### `SpeakerTracker.swift` (whole file)
```swift
public protocol SpeakerTracker: Sendable {
    func assign(window embedding: [Float]) async -> Int     // label of this window
    var previous: Int { get async }                         // last label assigned; 1 before any
}
```

### `CentroidTracker.swift`
```swift
public actor CentroidTracker: SpeakerTracker {
    private let config: ConfigStore
    private var sums: [[Double]] = [], pending: [[Double]] = []
    public private(set) var previous = 1
    public init(config: ConfigStore) { self.config = config }

    public func assign(window embedding: [Float]) async -> Int {
        let c = await config.current
        let e = unit(embedding.map(Double.init))
        let sims = sums.map { zip(e, unit($0)).reduce(0) { $0 + $1.0 * $1.1 } }
        if let best = sims.max(), best >= c.speakerThreshold {
            let k = sims.firstIndex(of: best)!
            sums[k] = zip(sums[k], e).map(+); pending = []; previous = k + 1
        } else {
            pending.append(e)
            if pending.count >= c.speakerConfirmWindows {
                sums.append(pending.reduce(into: [Double](repeating: 0, count: e.count)) { $0 = zip($0, $1).map(+) })
                pending = []; previous = sums.count
            }
        }
        return previous
    }
    private func unit(_ v: [Double]) -> [Double] { let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot(); return v.map { $0 / n } }
}
```
Constants `speakerThreshold` 0.35 and `speakerConfirmWindows` 4 are `Config` defaults (DECISIONS, Speakers), read on every call, so a live change applies at once. The tracker keeps no model: it is pure arithmetic on vectors.

### `SourcePipeline.swift` (regenerated whole; S2's file plus its "Review corrections", plus windows and runs)
```swift
import FluidAudio
import Foundation

struct SourcePipeline: Sendable {
    let source: any AudioSource
    let vad: VadManager
    let transcriber: Transcriber
    let embedder: Embedder
    let store: TranscriptStore
    let config: ConfigStore
    let tracker: any SpeakerTracker

    private struct Open {
        var start: Int
        var next: Int                                   // start of the next unembedded window
        var probs: [(end: Int, p: Float)] = []
        var wins: [(mid: Int, spk: Int)] = []
    }

    func run() async throws {
        let sr = Chunk.sampleRate, chunk = VadManager.chunkSize
        var base = 0, fed = 0, samples: [Float] = []    // samples[0] is source sample `base`; `fed` = next sample not yet sent to the VAD
        var state = VadStreamState.initial()
        var cfg = await config.current
        var open: Open? = nil

        func commit(_ o: Open, _ e: Int) async throws {
            let s = o.start
            let r = try await transcriber.transcribe(Array(samples[(s - base)..<(e - base)]))
            let words = buildWordTimings(from: r.tokenTimings!)             // Uncertainty 2
            guard !words.isEmpty else { return }                            // no blank captions
            let t0 = Double(s) / Double(sr), mine = o.wins.filter { $0.mid < e }
            let fallback = await tracker.previous
            let labels = words.map { w -> Int in
                let m = t0 + (w.startTime + w.endTime) / 2
                return mine.min { abs(Double($0.mid) / Double(sr) - m) < abs(Double($1.mid) / Double(sr) - m) }?.spk ?? fallback
            }
            var runs: [Range<Int>] = []                                     // maximal runs of equal label
            for i in words.indices { if let l = runs.last, labels[l.last!] == labels[i] { runs[runs.count - 1] = l.lowerBound..<i + 1 } else { runs.append(i..<i + 1) } }
            let now = Date()
            for (k, run) in runs.enumerated() {
                try await store.append(Line(
                    t: now, src: source.id, tag: source.tag, spk: labels[run.lowerBound],
                    text: words[run].map(\.word).joined(separator: " "),
                    start: k == 0 ? Double(s) / Double(sr) : t0 + words[run.lowerBound].startTime,       // Uncertainty 7
                    end: k == runs.count - 1 ? Double(e) / Double(sr) : t0 + words[run.upperBound - 1].endTime))
            }
        }
        func flush() async throws {
            guard let o = open else { return }
            try await commit(o, base + samples.count)
            open = nil
        }
        func embedWindows(_ o: inout Open) async throws {                   // Uncertainty 4
            let win = Int(cfg.speakerWindow * Double(sr)), hop = Int(cfg.speakerHop * Double(sr))
            while o.next + win <= fed {
                let w = Array(samples[(o.next - base)..<(o.next + win - base)])
                o.wins.append((o.next + win / 2, await tracker.assign(window: try await embedder.embed(w))))
                o.next += hop
            }
        }

        do {
            for try await c in source.chunks() {
                precondition(c.index == base + samples.count, "source chunks must be contiguous")
                samples += c.samples
                while fed + chunk <= base + samples.count {
                    let r = try await vad.processStreamingChunk(
                        Array(samples[(fed - base)..<(fed + chunk - base)]), state: state,
                        config: VadSegmentationConfig(minSilenceDuration: cfg.minSilence))
                    state = r.state
                    fed += chunk
                    if let e = r.event, e.isStart { cfg = await config.current; open = Open(start: e.sampleIndex, next: e.sampleIndex) }
                    open?.probs.append((fed, r.probability))
                    if let e = r.event, e.isEnd, let o = open {
                        try await commit(o, max(e.sampleIndex, o.start + 1))
                        open = nil
                    } else if var o = open {
                        try await embedWindows(&o)
                        open = o
                        if fed - o.start >= Int(cfg.maxSegment * Double(sr)) {
                            let cut = o.probs.filter { $0.end >= fed - 2 * sr }.min { $0.p < $1.p }!.end
                            try await commit(o, cut)
                            open = Open(start: cut, next: o.next, probs: o.probs.filter { $0.end > cut }, wins: o.wins.filter { $0.mid >= cut })
                            cfg = await config.current
                        }
                    }
                }
                let keep = open.map { min($0.start, $0.next) } ?? fed - 2 * chunk      // a window may start before a cut
                let drop = max(0, keep - base)
                samples.removeFirst(drop); base += drop
            }
        } catch {
            try? await flush()                                              // the source's error is the one reported
            throw error
        }
        try await flush()
    }
}
```
Origins: `2 * sr` (last 2 s for the cut) and `2 * chunk` (idle keep) are S2's; `win`, `hop`, `maxSegment`, `minSilence` come from `Config`. The cut keeps windows with `mid >= cut` for the next segment; the buffer keeps from `min(start, next)` because a window straddling the cut still needs its audio. `commit` uses one `Date()` per commit so the lines of a commit tie on `t` (S5 orders them stably).

### `Engine.swift` (regenerated whole; changes marked)
S2's file with: `private let embedder: Embedder`; `init(transcriber: Transcriber, embedder: Embedder, vad: VadManager, store: TranscriptStore, config: ConfigStore)`; `private var trackers: [SourceID: CentroidTracker] = [:]`; and in `attach`, replacing `SingleSpeaker()`:
```swift
let tracker = trackers[source.id, default: CentroidTracker(config: config)]
trackers[source.id] = tracker                      // lives for the engine start: detach and re-attach keep labels
let pipeline = SourcePipeline(source: source, vad: vad, transcriber: transcriber, embedder: embedder,
                              store: store, config: config, tracker: tracker)
```
Everything else is S2's text. `SingleSpeaker` no longer exists; `grep -r SingleSpeaker Sources Tests` must print nothing.

## S2 amendments (applied when S3 builds; nothing else in S2 changes)

`PipelineSupport.swift`: `Models` gains `static let embedder = Task { try await Embedder.load() }`; `makeEngine` passes `embedder: try await Models.embedder.value`; add
```swift
func splits(_ lines: [Line], by group: (Line) -> Int) -> Int    // adjacent pairs in one group with different spk
// = zip(lines, lines.dropFirst()).filter { group($0) == group($1) && $0.spk != $1.spk }.count
func turnOf(_ l: Line, _ turns: [Fixtures.Turn]) -> Int          // index of the turn whose [start,end] holds the line midpoint
```
`PipelineTests` test 1: delete the `spk == 1` assertion; `lines.count == 14` becomes `lines.count == 14 + splits(lines, by: { turnOf($0, turns) })`. Test 2: `lines.count == 5` becomes `lines.count == 5 + splits(lines, by: { _ in 0 })`. Test 3: delete the `lines.count == 14` assertion. The mutation lists keep working (`minSilence 0.25` ⇒ 16 + splits ≠ 14 + splits).

## Tests (category Speakers, class `SpeakerTests`, all real: Silero, Ultra, WeSpeaker, real fixtures)

Helpers private to `SpeakerTests.swift`:
```swift
struct Ref { let start, end: Double; let spk: String }
func refs(turns: [Fixtures.Turn]) -> [Ref]                      // turns.map { Ref($0.start, $0.end, $0.speaker) }
func refs(rttm: URL) -> [Ref]                                    // each line f = split(" "): Ref(Double(f[3]), Double(f[3]) + Double(f[4]), f[7])
func fx(_ name: String) -> URL                                   // Fixtures.dir.appending(path: name)
func bestMatch(_ cells: [Int: [String: Int]]) -> Int             // max total over one-to-one label↔truth assignments
    // cols = sorted truth speakers; dp: [mask: Int] = [0: 0]; for each label row: next = dp (row unassigned);
    // for (mask, v) in dp, for col not in mask: next[mask | 1<<col] = max(next[...] ?? 0, v + cells[row][col] ?? 0); dp = next; return dp.values.max()
func score(_ lines: [Line], wav: URL, ref: [Ref], _ tr: Transcriber) async throws -> (found: Int, accuracy: Double, words: Int)
    // audio = collect(FileSource(url: wav, id: "s", tag: "s")).flatMap(\.samples); cells = [:]; total = 0
    // for l in lines: a = Int((l.start*16000).rounded()), b = min(Int((l.end*16000).rounded()), audio.count)
    //   for w in buildWordTimings(from: try await tr.transcribe(Array(audio[a..<b])).tokenTimings!):
    //     m = l.start + (w.startTime + w.endTime)/2; who = Set(ref.filter { $0.start <= m && m < $0.end }.map(\.spk))
    //     if who.count == 1 { cells[l.spk, default: [:]][who.first!, default: 0] += 1; total += 1 }     // overlap words are skipped, as in the script
    // return (Set(lines.map(\.spk)).count, Double(bestMatch(cells)) / Double(total), total)
func speakerCase(_ name: String, wav: URL, ref: [Ref], found: (Int) -> Bool, foundText: String, minAccuracy: Double) async throws
    // (lines, ends, file) = runToEnd([FileSource(url: wav, id: SourceID(rawValue: name), tag: name)], temporaryRoot(self))
    // XCTAssertNil(ends[0].error); copy file to resultsDir()/speakers-<name>.jsonl
    // s = score(...); print("speakers \(name): found \(s.found)/\(foundText) accuracy \(s.accuracy) over \(s.words) words (bound \(minAccuracy))")
    // XCTAssertTrue(found(s.found)); XCTAssertGreaterThanOrEqual(s.accuracy, minAccuracy)
```
1. **`testTrackerNeedsFourConsecutiveWindowsForANewSpeaker`** (no models; literal vectors). `t = CentroidTracker(config: ConfigStore())`, `A = [1,0,0]`, `B = [0,1,0]` (cosine 0 < 0.35). Feed and expect exact label sequences:
   - `A×4` ⇒ `[1,1,1,1]` (a centroid exists from window 4); `B×3` ⇒ `[1,1,1]`; the 4th `B` ⇒ `2`; then `A` ⇒ `1`, `B` ⇒ `2`.
   - Fresh tracker: `A×4, B×3, A, B×3, B`. The `A` match clears `pending`, so the second run of `B` restarts its count. Assert exactly `[1,1,1,1, 1,1,1, 1, 1,1,1, 2]`.
   - `previous` is `1` on a fresh tracker and equals the last returned label afterwards.
   Mutations: confirm windows 1 ⇒ first `B` is `2` ⇒ red; threshold 0 ⇒ cosine 0 ≥ 0 matches A ⇒ B never `2` ⇒ red; not clearing `pending` on a match ⇒ the 12th label differs ⇒ red.
2. **`testWordsJoinToTheDecodeText`**. For turns 0…11: decode `turns/NN.wav` through `Transcriber`; `buildWordTimings(from: r.tokenTimings!).map(\.word).joined(separator: " ") == r.text` exactly, and `== Fixtures.oracleText(i)`. Guards Uncertainty 3 on measured data. Mutation: join with `""` ⇒ red.
3. **Seven accuracy cases**, each one test through `speakerCase`; bounds are DECISIONS minus 2 points, counts from STRATA:
   - `testConversation…`: `wav = Fixtures.conversationWav`, `refs(turns:)`, found `== 3`, ≥ 0.92 (measured 94.6).
   - `testAmi…`: `ami.wav`/`ami.rttm`, found `<= 5`, ≥ 0.94 (96.7, 5/4).
   - `testVox2…`: found `<= 4`, ≥ 0.90 (92.5, 4/2). `testVox3…`: `== 3`, ≥ 0.97 (99.2). `testVox4…`: `== 4`, ≥ 0.96 (98.5). `testVox6…`: `== 6`, ≥ 0.91 (93.6). `testVox9…`: `== 9`, ≥ 0.88 (90.8).
   Mutations (apply one, run `./test.sh Speakers`): `speakerThreshold` default 0 ⇒ conversation found 1 ⇒ red; `speakerConfirmWindows` default 1 ⇒ AMI found > 5 (measured 10) ⇒ red; every word of a commit takes `labels[0]` ⇒ AMI accuracy far below 0.94 ⇒ red; nearest window replaced by the first window of the segment ⇒ conversation/AMI below bound ⇒ red.
4. **`testSpeakerChangeInsideASegmentMakesTwoLines`** (replaces "a line never holds two labels"). `runToEnd([conv])`, `turns`. Assert there is at least one adjacent pair `(a, b)` with `turnOf(a) == turnOf(b)`, `a.spk != b.spk`, `b.start - a.end < 0.5` (a segment end needs at least 0.5 s of silence, so a gap under 0.5 s proves both lines came from one segment), and `a.text`, `b.text` non-empty. Expected from the design (a new speaker's first windows keep the old label, Uncertainty 8). Mutation: one label per segment (`labels[0]` for all words) ⇒ no such pair ⇒ red.
5. **`testReattachKeepsLabels`**. `(engine, store) = makeEngine(tmp)`; attach `FileSource(conv…)`, `awaitEnds(engine, 1)`, `n1 = snapshot().count`; `await engine.detach(id)` (no-op, already ended); attach a fresh `FileSource` with the same id; `awaitEnds(engine, 1)`; `pass1 = snapshot()[..<n1]`, `pass2 = snapshot()[n1...]`. Assert `Set(pass2.map(\.spk)) ⊆ Set(pass1.map(\.spk))` (no new speaker), and `splits(pass2, by: turnOf) < splits(pass1, by: turnOf)` (the known speakers are recognized from their first window, so the delayed-label splits are gone). Mutation: `Engine.attach` builds a fresh `CentroidTracker` every time ⇒ pass 2 repeats pass 1's data exactly ⇒ equal splits ⇒ red. The `<` is expected from the design, not yet measured: if the first build shows it false, stop and report; do not loosen it.

Human artefact: `test-results/<ts>/speakers-ami.jsonl` (the AMI session file) and the `speakers …` lines in `log.txt`.

## Attaining the result

1. `./test.sh Speakers` ⇒ green; prints `results: test-results/<ts>`; `grep '^speakers ' test-results/<ts>/log.txt` ⇒ seven found/accuracy lines.
2. `cut -c1-160 test-results/<ts>/speakers-ami.jsonl | head -40` ⇒ AMI lines with `spk` following the people.
3. Mutation pass as S1/S2 (by hand, filter only, `git checkout -- <file>`), red/green pairs in the commit message.
4. `./test.sh` (everything: S1 + S2 + S3) ⇒ green.

## Not in this stratum
Provisional tails and the current label for them (S4), the embedding soak (S4), live config-change tests for `speakerThreshold` (S14), cross-segment centroid merging (OTHER.md, deferred).

# Parent correction (overrides above)
No `SpeakerTracker` protocol and no `SingleSpeaker`: one implementation needs no protocol. S2 writes `spk: 1` directly; S3 adds `CentroidTracker` as a plain type.

# Review corrections (apply at build)
- S2's `cuts()` counts `$1.start == $0.end && $1.spk == $0.spk`: word-time splits can have equal times.
- Speaker counts in tests: count centroids, as measured, not distinct labels on lines.
- `CentroidTracker` takes threshold and confirm count as arguments, read by the pipeline at segment open; it does not read `ConfigStore`.
- Scoring: one whole-file `Transcriber` decode, each word assigned to the line containing its midpoint, instead of re-decoding line slices.
