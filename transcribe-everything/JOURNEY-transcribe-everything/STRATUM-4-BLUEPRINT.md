# Stratum 4 Blueprint — Live: provisional tail in the store

Builds on S1 (built), S2 (built, under test) and `STRATUM-3-BLUEPRINT.md` with its parent and review corrections (S3 is blueprinted, not built: S4 is written against that text). Ground truth: `Transcriber`, `TranscriptStore`, `SourcePipeline`, `Engine`, `Embedder`, `CentroidTracker`, test `Support`/`PipelineSupport`.

# Uncertainties squashed

1. **No FluidAudio API is new.** The only calls are S1/S2/S3's: `AsrManager.transcribe` (inside `Transcriber`), `VadManager.processStreamingChunk`, `VadStreamState.initial()`, `DiarizerManager.extractSpeakerEmbedding`. The queue, tails and notification are stdlib: `AsyncStream.makeStream(of:bufferingPolicy:)` (already used by S2's `Engine.ended`), `CheckedContinuation`, `getloadavg`, `task_info(TASK_VM_INFO)` (`spike/Sources/Bench/main.swift:7-17`, `footprintMB`, the soak's own measure).
2. **`Transcriber` today does not serialize.** It is an actor, but `transcribe` suspends inside `asr.transcribe`, so calls interleave. S4 adds a one-at-a-time gate; that gate is the queue. Throughput is unchanged: DECISIONS measured "6 sources saturate the Transcriber", i.e. the model is already the serial resource.
3. **Round-robin needs no code of its own.** The pipeline keeps at most one provisional decode per source (item 5), so the provisionals waiting in the queue come from distinct sources. Serving them in arrival order is round-robin: a source that finishes and resubmits goes behind the others. The test asserts it from the trace (test 3), not from the code.
4. **Cancellation is not needed.** Nothing cancels a pipeline's decode; a commit never waits behind a provisional (priority), and a stale provisional is dropped by the store, not by cancelling. So the queue has no cancellation handling.
5. **"Skipped while in flight; latest audio wins" read as: intermediate offers are dropped, the newest is decoded as soon as the previous decode ends.** One `AsyncStream` with `bufferingNewest(1)` per pipeline gives exactly that with no flag and no lock. It is never later than "wait for the next chunk" and never decodes stale audio. The test pins it: a source that stops delivering must still end on the decode of its final prefix (test 2; mutant `bufferingOldest(1)` ⇒ red).
6. **A provisional that lands after its segment committed must never show.** At a force-cut the next segment opens in the same step, so a late decode of the old segment would show as the new segment's tail. Fix: the store owns a per-source `epoch`, bumped by every commit; a tail write carries the epoch read at segment open and is dropped on mismatch. Exact (an integer identity set once where the segment opens), not a time or text heuristic. `commit` clears the tail and bumps the epoch inside one actor method, so no reader sees the lines and the tail together, or neither.
7. **Attach order of `tails`.** `Engine.attach` calls `store.epoch(of:)` first; the first call per source fixes its slot. Slots are an array, so `tails` order is attach order, never a dictionary's.
8. **Empty text never becomes a tail.** `setTail` stores `nil` for `""`, so `Snapshot.tails` holds only non-empty tails (S5's own filter stays harmless).
9. **The wait at the end of `run()`.** After the last commit the worker may still hold one buffered offer (its result is dropped by the epoch). `run()` finishes the offer stream and awaits the worker, so no task outlives the run and a worker error surfaces as the source's error. Cost: `detach` can wait for one extra low-priority decode. Not cancelled: whether FluidAudio throws on cancellation mid-decode is unprobed, and a `CancellationError` must not become the source's error.
10. **Tests cannot see the queue, so `Transcriber` reports it.** `pending` (decodes submitted and unfinished) makes test 1 deterministic; `observe` hands each finished decode's `{priority, submitted, started, finished}` to the latency test, which is how "queue wait counted, never added" is checked on measured data. Both are read-only; `observe(nil)` switches the recorder off.
11. **Timeline correlation.** One `Date()` clock everywhere (records, `line.t`, observations): no mixing with `ContinuousClock` instants. Serial service makes the record that produced a tail the provisional with the latest `finished` before the observation (decodes are ≥ 40 ms apart, the store hop is microseconds). Observation staleness is excluded exactly (test 3): a snapshot counts for turn `j` only if it already holds all of that source's lines for turns `< j`, because a commit clears the tail in the same call that appends them.
12. **Conversation is 99 s** (turns 0–11, ends at 99.0 s; `conversation.json`), so the paced run takes about 105 s. Turn 9 (62.6–78.0 s, 15.4 s) is the long turn: its midpoint is before any force-cut (12 s), used by test 2.
13. **Resolves OTHER.md:** S4 "add 14,000 VAD chunks to the soak" (done, test 4) and S3 item 12(b) "the soak includes 7,200 embeddings through the same `Embedder`" (done, test 4). **Adds to OTHER.md:** (a) S10: when `flush` itself throws, `store.commit` is not reached and the source's tail stays; S10's failure path must call `store.commit([], of: id)`. (b) A decode error in the live worker surfaces only when the source ends (item 9); revisit if real use shows long failures there.
14. **Decisions to record in DECISIONS.md at build:** latency embed term = number of sources × the embed max measured in the test (30 idle runs, about 1 s, the embedder is one serial actor); load limit = `activeProcessorCount` (above it runnable threads outnumber cores; the one measured point, load 26 on 16 cores, tripled decode time); soak median bound is one-sided (`last ≤ 1.2 × first`: slower is the defect); soak runs serially like `Bench soak` (parallel decode/embed/VAD would change the contention that the 20% bound was measured against; the test's subject is a leak, not throughput).

# Blueprint

## Files
```
Sources/TECore/TranscriptStore.swift   (regenerated whole)
Sources/TECore/Transcriber.swift       (regenerated whole)
Sources/TECore/SourcePipeline.swift    (regenerated whole from the built S3 file + edits E1–E5)
Sources/TECore/Engine.swift            (one line + `async`)
Tests/TECoreTests/StoreTests.swift     (regenerated whole)
Tests/TECoreTests/PipelineSupport.swift, PipelineTests.swift, SpeakerTests.swift  (`.lines`; `HangingSource` added)
Tests/TECoreTests/LiveTests.swift      (new, category Live)
```
Every `snapshot()` caller reads `.lines`; `append` no longer exists. After the edits `grep -rn "store.append\|\.append(Line" Sources Tests` prints nothing, and the build proves no `[Line]`-typed snapshot remains.

### `TranscriptStore.swift` (whole file)
```swift
import Foundation

public struct Provisional: Equatable, Sendable {
    public var src: SourceID, tag: String, spk: Int, text: String   // spk = the current label
    public init(src: SourceID, tag: String, spk: Int, text: String) {
        self.src = src; self.tag = tag; self.spk = spk; self.text = text
    }
}

public struct Snapshot: Equatable, Sendable {
    public var lines: [Line]          // committed, append order
    public var tails: [Provisional]   // open segments with text, one per source at most, attach order
    public init(lines: [Line], tails: [Provisional]) { self.lines = lines; self.tails = tails }
}

/// One per engine start. Sole owner of displayed text.
public actor TranscriptStore {
    public nonisolated let file: URL
    /// Yields after every change. Coalesced: a reader redraws from `snapshot()`, so only "changed" matters.
    public nonisolated let changes: AsyncStream<Void>
    private let notify: AsyncStream<Void>.Continuation
    private let handle: FileHandle
    private var lines: [Line] = []
    private var slots: [Slot] = []   // attach order
    private struct Slot { let src: SourceID; var epoch = 0; var tail: Provisional? }
    private static let isoMs = ...            // unchanged from S1
    private static let encoder = ...          // unchanged from S1

    public init(paths: Paths, start: Date = Date()) throws {
        (changes, notify) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))   // 1: see `changes`
        ... rest of S1's init unchanged
    }

    /// The segment id for tail writes. The first call per source fixes its place in `Snapshot.tails`.
    public func epoch(of src: SourceID) -> Int { slots[index(of: src)].epoch }

    /// Dropped when `epoch` is not the source's current one: that segment already committed.
    public func setTail(_ tail: Provisional, epoch: Int) {
        let i = index(of: tail.src)
        guard slots[i].epoch == epoch else { return }
        slots[i].tail = tail.text.isEmpty ? nil : tail
        notify.yield()
    }

    /// The only write of committed lines. Appends them, clears the source's tail and ends its segment, in one step.
    public func commit(_ new: [Line], of src: SourceID) throws {
        defer { notify.yield() }
        let i = index(of: src)
        slots[i].tail = nil
        slots[i].epoch += 1
        for line in new {
            try handle.write(contentsOf: Self.encoder.encode(line) + [0x0A])
            lines.append(line)
        }
    }

    public func snapshot() -> Snapshot { Snapshot(lines: lines, tails: slots.compactMap(\.tail)) }

    private func index(of src: SourceID) -> Int {
        if let i = slots.firstIndex(where: { $0.src == src }) { return i }
        slots.append(Slot(src: src))
        return slots.count - 1
    }
}
```
`commit` with `new == []` is legal and required: a blank decode still closes the segment. The single-owner rule holds: tails, epochs and lines change only here.

### `Transcriber.swift` (whole file)
```swift
import FluidAudio
import Foundation

public enum Priority: Sendable { case commit, provisional }

/// One finished decode, for latency tests.
public struct Decode: Sendable {
    public let priority: Priority
    public let submitted, started, finished: Date
}

public actor Transcriber {
    private let asr: AsrManager
    private var busy = false
    private var waiting: [(priority: Priority, go: CheckedContinuation<Void, Never>)] = []
    private var onDecode: (@Sendable (Decode) -> Void)?
    private init(_ asr: AsrManager) { self.asr = asr }

    public static func load() async throws -> Transcriber { ... }   // unchanged

    public var pending: Int { waiting.count + (busy ? 1 : 0) }
    public func observe(_ f: (@Sendable (Decode) -> Void)?) { onDecode = f }

    /// One decode at a time. Commits are served first; provisionals in arrival order, which is round-robin because each source queues at most one.
    public func transcribe(_ samples: [Float], priority: Priority = .commit) async throws -> ASRResult {
        let submitted = Date()
        if busy { await withCheckedContinuation { waiting.append((priority, $0)) } } else { busy = true }
        let started = Date()
        defer {
            onDecode?(Decode(priority: priority, submitted: submitted, started: started, finished: Date()))
            if let i = waiting.firstIndex(where: { $0.priority == .commit }) ?? waiting.indices.first {
                waiting.remove(at: i).go.resume()   // `busy` stays true: the model passes straight to the next
            } else { busy = false }
        }
        // FluidAudio rejects audio under 0.3 s.   (S1's body, unchanged)
        let short = max(0, ASRConstants.minimumRequiredSamples(forSampleRate: Chunk.sampleRate) - samples.count)
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples + [Float](repeating: 0, count: short), decoderState: &state)
    }
}
```
The priority queue itself is 6 lines (`busy`, `waiting`, the `if busy` line, the `defer` hand-off); the rest is recording. S1/S2/S3 callers keep calling `transcribe(samples)` and get `.commit`.

### `Engine.swift`
`attach` becomes `public func attach(_ source: any AudioSource) async` and its first line is
```swift
_ = await store.epoch(of: source.id)   // fixes the source's place in tails: attach order
```
before the `precondition` (the await comes first so the check-and-set below stays atomic). Callers already `await` it (actor method).

### `SourcePipeline.swift` — edits E1–E5 to the built S3 file (read it whole, regenerate it whole; nothing else changes)
Add inside the file:
```swift
private struct Offer: Sendable { let epoch: Int, spk: Int, samples: [Float] }
```
**E1** (top of `run()`, after the state variables):
```swift
let (latest, offer) = AsyncStream.makeStream(of: Offer.self, bufferingPolicy: .bufferingNewest(1))   // 1: the newest audio replaces an undecoded older one
let live = Task {
    for await w in latest {
        let text = try await transcriber.transcribe(w.samples, priority: .provisional).text
        await store.setTail(Provisional(src: source.id, tag: source.tag, spk: w.spk, text: text), epoch: w.epoch)
    }
}
```
**E2** (`Open` gains `let epoch: Int` right after `next`; both creation sites read it):
```swift
open = Open(start: e.sampleIndex, next: e.sampleIndex, epoch: await store.epoch(of: source.id))
...                                                  // after `try await commit(o, cut)`:
open = Open(start: cut, next: o.next, epoch: await store.epoch(of: source.id), probs: ..., wins: ...)
```
**E3** (`commit`: S3's early `return` on no words and its per-line `store.append` loop become):
```swift
guard !words.isEmpty else { return try await store.commit([], of: source.id) }   // a blank decode still ends the segment
... labels and runs exactly as S3 ...
let now = Date()
try await store.commit(runs.enumerated().map { k, run in
    Line(t: now, src: source.id, tag: source.tag, spk: labels[run.lowerBound], text: words[run].map(\.word).joined(separator: " "),
         start: <S3's start expression>, end: <S3's end expression>)
}, of: source.id)
```
**E4** (inside the VAD `while`, after S3's whole `if let e = r.event, e.isEnd … else if var o = open { … }` chain; an end event leaves `open == nil`, so nothing is offered then, and a force-cut offers the new segment):
```swift
if let o = open {
    offer.yield(Offer(epoch: o.epoch, spk: await tracker.previous,   // same expression S3's commit uses for `fallback`
                      samples: Array(samples[(o.start - base)..<(fed - base)])))
}
```
`o.start - base ≥ 0` holds by S3's buffer rule (`keep = min(start, next)`); a cut at `fed` gives an empty slice, which `Transcriber` pads.
**E5** (end of `run()`):
```swift
do { for try await ... } catch {
    try? await flush()
    offer.finish(); _ = await live.result      // the source's error is the one reported
    throw error
}
try await flush()
offer.finish()
try await live.value
```

## Tests

### Support (`PipelineSupport.swift`)
Replace `await store.snapshot()` with `await store.snapshot().lines` in `runToEnd`, `PipelineTests` (`testDetachCommits…`) and S3's `SpeakerTests` (`testReattachKeepsLabels`). Add:
```swift
/// Yields chunks up to sample `upTo`, then delivers nothing until `stop()`: a live source that has gone quiet.
final class HangingSource: TECore.AudioSource {
    let base: FileSource, upTo: Int
    var id: SourceID { base.id }
    var tag: String { base.tag }
    private let cont = OSAllocatedUnfairLock<AsyncThrowingStream<Chunk, Error>.Continuation?>(initialState: nil)
    init(base: FileSource, upTo: Int) { self.base = base; self.upTo = upTo }
    func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            cont.withLock { $0 = c }
            let t = Task { for try await ch in base.chunks() where ch.index + ch.samples.count <= upTo { c.yield(ch) } }
            c.onTermination = { _ in t.cancel() }
        }
    }
    func stop() { cont.withLock { $0?.finish() } }
}
```
(`import os`.)

### `StoreTests.swift` (whole file; category Store, no models)
S1's three tests keep their assertions; every `store.append(l)` becomes `store.commit([l], of: l.src)` and `store.snapshot()` becomes `store.snapshot().lines`. New, with `P(src, text)` = `Provisional(src:, tag: src, spk: 1, text:)`:

1. **`testCommitEndsTheSegmentAtomicallyAndALateTailIsDropped`** — A: `e0 = epoch(of: A)` is 0; `setTail(P(A,"hel"), epoch: 0)` ⇒ `tails == [P]`; `commit([L], of: A)` ⇒ one snapshot read: `lines == [L]`, `tails == []`; `epoch(of: A) == 1`; `setTail(P(A,"late"), epoch: 0)` ⇒ `tails == []`; `setTail(P(A,"new"), epoch: 1)` ⇒ `[P new]`; `setTail(P(A,""), epoch: 1)` ⇒ `[]`; `commit([], of: A)` leaves `lines` unchanged and bumps the epoch to 2. Mutants: commit does not clear the tail ⇒ red; does not bump the epoch ⇒ the `"late"` row red; `setTail` ignores the epoch ⇒ red; stores `""` ⇒ red.
2. **`testNoReaderSeesALineTogetherWithItsOwnTail`** — a writer task: for `n` in 0..<500, `setTail(P(A,"t\(n)"), epoch: n)` then `commit([L(text: "t\(n)")], of: A)`. Four reader tasks each take 2,000 snapshots (`await Task.yield()` between). Assert, in every snapshot, that no tail text also appears as a committed line's text. 500 and 2,000 are sampling depth, not bounds: with 4 readers the window of a non-atomic commit is hit in the mutant (a `await Task.yield()` between the line writes and the tail clear) within the first few hundred iterations. Mutant: that yield ⇒ red.
3. **`testTailsAreInAttachOrderNotWriteOrder`** — `epoch(of: B)`, `epoch(of: A)`, `epoch(of: C)`; `setTail` for A, then C, then B ⇒ `tails.map(\.src) == [B, A, C]`. Mutant: order by first write ⇒ red.
4. **`testEveryWriteWakesTheReader`** — `var it = store.changes.makeAsyncIterator()`. `setTail` ⇒ `await it.next() != nil`; `commit` ⇒ `await it.next() != nil`. Coalescing is a design choice (`bufferingNewest(1)`), not tested: a reader redraws from `snapshot()` either way. Mutants: no `notify` in `setTail`, or in `commit` ⇒ `next()` never returns ⇒ red by the time limit (`executionTimeAllowance = 60`).

### `LiveTests.swift` (category Live; real Silero, Ultra, WeSpeaker, real fixtures)
Private helpers:
```swift
func requireIdleMachine() throws       // getloadavg(&l, 1); l[0] > Double(ProcessInfo.processInfo.activeProcessorCount)
    // ⇒ XCTFail("machine load \(l[0]) exceeds \(cores) cores: decode time triples at load 26 (DECISIONS); latency bounds do not apply"); throw Busy()
func footprintMB() -> Double           // vendored from spike/Sources/Bench/main.swift:7-17, phys_footprint
func median(_ xs: [Double]) -> Double
func seconds(_ a: Date, _ b: Date) -> Double   // b - a
```

1. **`testCommitIsServedBeforeQueuedProvisionals`** — deterministic, real model. `tr = Models.transcriber`; `long` = the conversation's samples (`collect(conv)`, 99 s, a decode of several chunks: the model stays busy for hundreds of ms while the queue fills); `short` = `Fixtures.turnWav(0)` samples. `log = OSAllocatedUnfairLock<[String]>`. `submit(name, audio, priority)` starts a `Task { _ = try await tr.transcribe(audio, priority: p); log.append(name) }`. Submit `P0` (long, provisional); for each of `(P1, .provisional)`, `(P2, .provisional)`, `(C, .commit)`: first `while await tr.pending < tasks.count { await Task.yield() }` (all earlier submissions are queued or running), then submit. Await all tasks. Assert `log == ["P0", "C", "P1", "P2"]`. Mutant: the hand-off takes `waiting.indices.first` (FIFO) ⇒ `["P0","P1","P2","C"]` ⇒ red. The wait loops cannot hang unless `P0` ends before the next submit, which would take longer than hundreds of ms; the test time limit (`executionTimeAllowance = 60`) turns that into a red test.

2. **`testProvisionalIsAFreshDecodeOfTheOpenSegmentAndCommitClearsIt`** — `convFile()` as in `PipelineTests`.
   a. `lines = runToEnd([conv])`; `turns`; `s` = `Int((lines.first { turnOf($0, turns) == 9 }!.start * 16000).rounded())` (the first run of a segment starts at the segment's sample, S3 uncertainty 7); `audio = collect(conv).flatMap(\.samples)`.
   b. `n = s + 6 * 16000`; `fed = n / 4096 * 4096` (every sample the pipeline sends to the VAD); `expected = try await Models.transcriber.value.transcribe(Array(audio[s..<fed])).text`.
   c. Fresh engine; `engine.attach(HangingSource(base: conv, upTo: n))`. Poll every 10 ms (a sampling period, not a bound) until `store.snapshot().tails.first?.text == expected`. Assert that tail has `src == convID`, `tag == "conv"`. A tail that never equals the decode of exactly `[s, fed)` runs the test into its time limit (`executionTimeAllowance = 120`).
   d. `await engine.detach(convID)`; `ends = awaitEnds(engine, 1)`; assert no error; `snapshot`: `tails.isEmpty` (the commit cleared it), `lines` non-empty with every line's `start ≥ Double(s) / 16000 - 0.5` (only the one open segment and the earlier turns' commits exist; the check that matters is the last line), `lines.last!.end == Double(fed) / 16000`, `lines.last!.text` non-empty.
   Mutants: no offer (E4 removed) ⇒ red by time limit; the offer carries `samples.suffix(2 * sr)` ⇒ text ≠ expected ⇒ red; `bufferingOldest(1)` ⇒ the final prefix is never decoded after the source stalls ⇒ red; `setTail` never called ⇒ red; commit does not clear the tail ⇒ step d red.

3. **`testThreeSourcesInRealTimeMeetTheLatencyBounds`** — `executionTimeAllowance = 300`. Result table: `resultsDir()/latency.md`.
   Setup: `try requireIdleMachine()`; `tr = Models.transcriber`; `records = OSAllocatedUnfairLock<[Decode]>`; `await tr.observe { d in records.withLock { $0.append(d) } }`; `addTeardownBlock { await tr.observe(nil) }`. `embedMax` = max of 30 idle `Models.embedder.embed` calls on one 32,000-sample window of turn 0, timed with `Date()`. `(engine, store) = makeEngine(...)`. A watcher task: `for await _ in store.changes { let s = await store.snapshot(); seen.append((Date(), s)) }` (timestamp after the read).
   Run: for `k` in 0..<3: construct `FileSource(url: conversationWav, id: "s\(k)", tag: "c\(k)", clock: ContinuousClock())` first, `sleep(1 s)` before `k > 0`, then `start[k] = Date()` and `await engine.attach(src)` (starts 0, 1, 2 s apart). `ends = awaitEnds(engine, 3)`; cancel the watcher; `lines = snapshot().lines`; `try requireIdleMachine()` again (a load spike during the run fails with its reason, not as timing).
   For each source `k`, turn `j` (`w = Fixtures.oracleWords(j)`): `onset = start[k] + turns[j].start + w.first.start`, `lastWord = start[k] + turns[j].start + w.last.end`. Helpers over `records`:
   - `inflight(r)` = `ran` of the record `x ≠ r` with `x.started < r.submitted < x.finished`, else 0.
   - `ahead(r)` = records `x ≠ r` with `r.submitted ≤ x.started < r.started` (what was served while `r` waited).
   - Commit check. `mine = lines of source k with turnOf == j`; `t = mine.map(\.t).max()`; `c` = the `.commit` record with the largest `finished ≤ t`. Assert (i) every record in `ahead(c)` is `.commit` (priority held, exact, no time tolerance); (ii) `seconds(lastWord, t) ≤ 1.28 + ran(c) + 3 * embedMax + inflight(c) + Σ ran(ahead(c))` (DECISIONS: 1.28 s, its decode, embed, one in-flight decode, commits queued ahead × decode; the queue wait itself is never an addend).
   - First-provisional check. `before = lines of source k with turnOf < j` (count `nPrev`); `valid` = observations whose snapshot holds ≥ `nPrev` lines of source k (the previous turns' commits are in, so their tails are gone); `tFirst` = the smallest `t` among `valid` with a tail for source k; assert it exists. `p` = the `.provisional` record with the largest `finished ≤ tFirst`. Assert (i) `ahead(p).filter { $0.priority == .provisional }.count ≤ 2` (round-robin: at most one provisional from each other source is served before `p`); (ii) `seconds(onset, tFirst) ≤ 0.866 + ran(p) + inflight(p) + Σ ran(ahead(p))` (DECISIONS: 0.866 s plus that decode plus the round-robin wait counted from the queue).
   Write one table row per `(k, j)`: first-text latency and bound, commit latency and bound; print the file.
   Mutants (each run by hand, `./test.sh Live`): the pipeline's commit decodes with `priority: .provisional` ⇒ commits queue behind provisionals ⇒ check (i) red; the hand-off takes FIFO ⇒ (i) red on commits; the hand-off takes the newest provisional (LIFO) ⇒ round-robin count red; the pipeline never offers ⇒ no tail ⇒ red; `commit` awaits the live worker before writing to the store ⇒ commit bound red.
   The embed term and `3` (sources) are a decision (item 14). If the first build fails a bound, stop and report the measured table; do not loosen.

4. **`testSoak`** — 14,000 growing-prefix decodes, 7,200 embeddings and 14,000 VAD chunks through the real `Transcriber`, `Embedder` and `VadManager`, serial and interleaved as `Bench soak`. `executionTimeAllowance = 1800` (measured about 19 min plus VAD, ×1.5). `try requireIdleMachine()` at start and end.
   ```
   audio = collect(FileSource(url: Fixtures.dir/ami.wav)).flatMap(\.samples)
   vadState = VadStreamState.initial(); offset = 0; grow = 1; embeds = 0; vadAt = 0; times = []; medians = []; footprints = []
   for n in 1...14_000:
       len = grow * 4096                                   // Transcriber pads under 0.3 s
       if offset + len > audio.count { offset = 0 }
       t0 = Date(); transcribe(audio[offset..<offset + len], priority: .provisional); times += Date() - t0
       grow += 1; if grow > 46 { grow = 1; offset += 46 * 4096 }          // 46 chunks = 11.8 s, under the 12 s cut
       while Double(embeds) < Double(n) * 7200 / 14000:    // 7,200 total, as measured
           e = min(offset + 32000, audio.count); embed(audio[(e - 32000)..<e]); embeds += 1
       lo = (vadAt % (audio.count / 4096)) * 4096; vadState = vad.processStreamingChunk(audio[lo..<lo + 4096], state: vadState, config: VadSegmentationConfig(minSilenceDuration: 0.5)).state; vadAt += 1
       if n % 1000 == 0: medians += median(times); footprints += footprintMB(); times = []
   ```
   Assert: `footprints[13] - footprints[3] ≤ 20` (growth after the first 4,000 decodes; measured 4 MB, bound 20 MB from STRATA); `medians.last! ≤ 1.2 * medians.first!` (STRATA 20%, one-sided: item 14); `embeds == 7200`. Write `soak.md` (bucket, median ms, footprint MB) to `resultsDir()`.
   Mutants: `Transcriber` keeps every `ASRResult` in an array ⇒ footprint growth above 20 MB ⇒ red (one 20-minute run, in the background under pacemaker; the only mutant that costs this long). The 20% bound's mutant: `Transcriber` re-sorts a growing log on every decode ⇒ median climbs ⇒ red, run only if the leak mutant leaves doubt.

## Attaining the result (in order)
1. `./test.sh Store` ⇒ green (fast, no models).
2. `./test.sh Live/testCommit` and `./test.sh Live/testProvisional` ⇒ green.
3. `./test.sh Live/testThreeSources` ⇒ green; `cat test-results/<ts>/latency.md` ⇒ per-turn first-text and commit latency with their bounds, 36 rows. This is the human-verifiable result.
4. `./test.sh Live/testSoak` in the background (`pacemaker`), about 20 minutes ⇒ green; `cat test-results/<ts>/soak.md`.
5. Mutation pass by hand (filter only, `git checkout -- <file>`), red/green pairs in the commit message.
6. `./test.sh` (everything S1–S4, S3's speaker tests included) ⇒ green. Then a FRESH adversarial review of the S4 diff against `~/minh-agent-doctrines/code-principles.md`, rounds until no HIGH or MEDIUM; then commit.

## Not in this stratum
Rendering and `Rendered.nextChange` (S5), the consumer of `changes` (S11), clearing a failed source's tail when `flush` throws (S10), config-change tests (S14), any cancellation of queued decodes.

# Review corrections (apply at build; these override the sections above)
- Drop `Open.epoch` and the store reads at segment open. `store.commit` returns the new epoch (`@discardableResult`); the pipeline keeps one local `epoch`, read at run start and reassigned from each commit's return, including the blank-decode path. Offers carry it.
- Add to the provisional test a run past the 12 s cut: the tail equals a fresh decode of `[cut, fed)`. Kills the stale-epoch and late-old-decode mutants.
- Measure embedding durations in the run for the commit bound, not idle.
- `setTail` drops blank text, so first-text timing is what the paced run shows; if a bound is red on the first run, stop and report, never loosen.
