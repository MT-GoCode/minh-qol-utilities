# Stratum 1 Blueprint — Store, config, file source, Ultra

# Uncertainties squashed

All FluidAudio paths below are under `~/general-purpose/conversation-contexts/transcribe-everything/vendor-src/FluidAudio` (tag v0.18.0, same revision as `spike/Package.resolved`, e152879).

1. **CLI config vs `ASRConfig.default`.** `Sources/FluidAudioCLI/Commands/ASR/Parakeet/SlidingWindow/TranscribeCommand.swift:641-649` builds `ASRConfig(tdtConfig: TdtConfig(blankId: v.blankId), encoderHiddenSize: v.encoderHiddenSize, melChunkContext: nil, dualDecodeArbitration: false, seamGapRepair: true, seamTimingRealignment: true)`. The last four are the CLI's parsed defaults (`:224-227`) and equal the `ASRConfig.init` defaults (`Sources/FluidAudio/ASR/Parakeet/AsrTypes.swift:64-76`). For `.ultra`, `blankId` = 8192 (`AsrModels.swift:66`) and `encoderHiddenSize` = 1024 (`:58`), equal to `TdtConfig` and `ASRConstants` defaults (`TdtConfig.swift:17`, `ASRConstants.swift:24`). So the spike's `.default` already equalled the CLI; `Transcriber` still builds the config from the version's properties, so one `let version` is the only place the model is named. `AsrManager` also adapts both fields to the loaded model on every call (`AsrManager.swift:300-322`).
2. **CLI model load.** `loadModels` (`TranscribeCommand.swift:622-634`) with no flags calls `AsrModels.downloadAndLoad(version: .ultra, encoderPrecision: .int8, encoderComputeUnits: nil)`; `:222-223` confirm the defaults. `AsrModels.downloadAndLoad(to:configuration:version:encoderPrecision:encoderComputeUnits:progressHandler:)` is at `AsrModels.swift:797`, so `downloadAndLoad(version: .ultra)` is identical.
3. **CLI URL overload vs samples path.** `AsrManager.transcribe(_ url:, decoderState:, language:)` (`AsrManager.swift:434-456`) takes the disk-backed branch only when estimated samples > `config.streamingThreshold` = 480,000 (30 s, `AsrTypes.swift:24,71`). Otherwise it runs `audioConverter.resampleAudioFile(url)` then `transcribe(samples, ...)`. The longest conversation turn is 15.4 s (`fixtures/conversation.json`), so the CLI takes the same samples path as `FileSource` + `Transcriber`. The oracle test asserts each turn is under 480,000 samples, so a longer fixture fails loudly rather than comparing two different code paths. The CLI is invoked as `fluidaudiocli transcribe <wav> --model-version ultra --output-json <out>` (`scratch/oracle.py`, which produced the recorded 6/242).
4. **Padding.** `transcribeWithState` throws `ASRError.invalidAudioData` below `ASRConstants.minimumRequiredSamples(forSampleRate:)` = Int(16000 × 0.3) = 4800 (`AsrManager+Transcription.swift:9-10`, `ASRConstants.swift:15,110-112`; `public static`). Inputs ≥ 4800 samples are not touched, so equality with the CLI holds.
5. **Public API used, all verified in source:** `AsrModelVersion.ultra/.blankId/.encoderHiddenSize` (`AsrModels.swift:5,54,63`), `TdtConfig(blankId:)` (`TdtConfig.swift:12`), `ASRConfig(tdtConfig:encoderHiddenSize:)`, `AsrManager(config:)` (`AsrManager.swift:96`, an `actor`), `loadModels(_:)` (`:189`), `decoderLayerCount` (`:26`, public), `TdtDecoderState.make(decoderLayers:)` (`TdtDecoderState.swift:52`), `transcribe(_ samples:[Float], decoderState: inout, language:)` (`AsrManager.swift:535`) returning `ASRResult` (`text`, public, `AsrTypes.swift:118`), `AudioConverter().resampleAudioFile(_ url:) throws -> [Float]` (`AudioConverter.swift:91`), `VadManager.chunkSize` = 4096 (`VadManager.swift:22`, public static), `VadManager()` async-throwing init that downloads and loads (`:79`), `DiarizerModels.download(to:configuration:progressHandler:)` (`DiarizerModels.swift:41`).
6. **`swift test` flags (measured on a throwaway package, Swift 6.4.2).** `--xunit-output` with XCTest writes the XML **only with `--parallel`**; without it only `<path>-swift-testing.xml` appears (empty). `--parallel --num-workers 1` writes `out.xml` with `<testcase classname="ATests.StoreTests" name="testOne">` and runs serially. `swift test -c release` runs a test target that uses only `public` API with no `-enable-testing`. Test framework: XCTest (classes are the categories, `classname` is the category in the XML).
7. **Build lock (resolves OTHER.md S1 item).** While `swift test --skip-build` was running a 15 s test, a concurrent `swift build` in the same package printed "Another instance of SwiftPM … waiting" and took 13 s. The lock is held for the whole test run. **Decision for S6:** `build.sh` builds with its own `--scratch-path .build-app`, so `AppHarness` can build mid-test. `.gitignore` lists it now.
8. **`fluidaudiocli` build without a checkout copy of our own.** `swift build -c release --product fluidaudiocli --package-path <FluidAudio checkout> --scratch-path <dir>` built the product in 98 s from a clean scratch dir (probed on vendor-src, same tag). In our repo the checkout is `.build/checkouts/FluidAudio`, created by `swift package resolve`. The scratch dir is `~/Library/Caches/transcribe-everything/fluidaudiocli-build`, so the checkout is not written to and tests' `.build` lock is not involved.
9. **`setup.sh` with no CLI (resolves OTHER.md S1 item).** The package has one executable `TranscribeEverything`; its only S1 behaviour is `prefetch`. `Transcriber.load()` is called (not just `download`) so the one-time Core ML / ANE compile (11.3 s, DECISIONS) happens at setup. `VadManager()` downloads Silero. `DiarizerModels.download()` fetches the WeSpeaker model (cache dir `speaker-diarization` exists locally).
10. **ISO-8601 with fractions.** `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` exists and **truncates** to ms: 1_700_000_000.123 formatted `2023-11-14T22:13:20.122Z`, parsed back −0.99999 ms. Tests therefore use exactly representable fractions (.5, .25), so string equality is exact.
11. **`Sources` test category (resolves OTHER.md S1 item).** Assigned here: `SourcesTests` holds the `FileSource` tests. S7/S8 keep `Capture`/`Mic`.
12. **Fixture facts.** Speakers sorted index 20, 21, 22 in LibriSpeech test-clean are 4970, 4992, 5105 (matches `fixtures/conversation.json`); `continuous` uses 4970 (index 20), utterances `[4:]`. Local AMI wav: 16 kHz mono 16-bit, 1049.4 s. Local VoxConverse clips: 16 kHz mono 16-bit, durations vox2 572.2, vox3 430.7, vox4 513.4, vox6 172.3, vox9 225.0 s, speaker counts 2/3/4/6/9 from their RTTMs. VoxConverse selection logic is `/tmp/vox2.py` (copied below as pseudocode; its output is what S3's bounds were measured on).
13. **Deliberate deferrals (not in STRATA's S1 verifiable execution, first consumer later, adding is a new method).** `ConfigStore.changes()` (first consumer S14/S11) and `TranscriptStore.changes()` (S4 tails, S11 overlay). Both are additive. No abstraction is made from a single occurrence. `Transcriber` is a plain serializing actor here; the priority queue is S4. `ConfigStore` has no test in S1; S2's pipeline reads it and exercises it.
14. **Not checkable now (no code exists), settled at build:** running the real `Oracle` test under the `xctest` host loads Ultra on the ANE. Evidence it works: the unsigned `Bench` executable did (DECISIONS); it fails loudly with a Core ML error otherwise (no fallback path exists).

# Blueprint

Package root is the repo root `transcribe-everything/` (the spike's own `spike/Package.swift` is a separate nested package SwiftPM ignores). Swift 6.4.2, `swift-tools-version: 6.0`.

## Files

```
.gitignore
Package.swift
Sources/TECore/{Paths,Config,Line,TranscriptStore,AudioSource,FileSource,Transcriber}.swift
Sources/TranscribeEverything/main.swift
Tests/TECoreTests/{Support,StoreTests,SourcesTests,OracleTests}.swift
setup.sh  test-setup.sh  fixtures.py  test.sh
```

### `.gitignore`
```
.build/
.build-app/
test-results/
```

### `Package.swift`
```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TranscribeEverything",
    platforms: [.macOS(.v15)],                       // spike/Package.swift
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0")],
    targets: [
        .target(name: "TECore", dependencies: ["FluidAudio"]),
        .executableTarget(name: "TranscribeEverything", dependencies: ["TECore", "FluidAudio"]),
        .testTarget(name: "TECoreTests", dependencies: ["TECore", "FluidAudio"]),   // FluidAudio: tests read ASRResult.text
    ],
    swiftLanguageModes: [.v5]                        // spike used v5 with FluidAudio
)
```
Copy `spike/Package.resolved` to `Package.resolved` (same pin) so resolve does not move the revision.

### `Sources/TECore/Paths.swift`
```swift
public struct Paths: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".transcribe-everything")) { self.root = root }
    public var transcripts: URL { root.appending(path: "transcripts") }
}
```

### `Sources/TECore/Config.swift`
```swift
public struct Config: Codable, Equatable, Sendable {
    // Defaults: DECISIONS.md (Segmentation, Speakers, Store and display).
    public var minSilence = 0.5, maxSegment = 12.0
    public var speakerThreshold = 0.35, speakerWindow = 2.0, speakerHop = 0.5, speakerConfirmWindows = 4
    public var windowSeconds = 20.0, expandedSeconds = 60.0
    public var fontSize = 22, fontSizeRange = 12...48
    public init() {}
}
public actor ConfigStore {
    public private(set) var current: Config
    public init(_ initial: Config = Config()) { current = initial }
    public func set(_ config: Config) { current = config }
}
```

### `Sources/TECore/AudioSource.swift`
```swift
public struct SourceID: RawRepresentable, Hashable, Codable, Sendable {   // encodes as a plain JSON string
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
public struct Chunk: Sendable {
    public static let sampleRate = 16_000
    public let samples: [Float]      // 16 kHz mono
    public let index: Int            // sample index of samples[0] on the source's clock
}
public protocol AudioSource: Sendable {
    var id: SourceID { get }
    var tag: String { get }
    func chunks() -> AsyncThrowingStream<Chunk, Error>   // finish = ended; throw = failed
    func stop()                                          // finishes the stream
}
```
`Chunk` needs an explicit `public init(samples:index:)` (memberwise is internal).

### `Sources/TECore/FileSource.swift`
```swift
import FluidAudio
import os

public final class FileSource: AudioSource {
    public let id: SourceID, tag: String
    private let samples: [Float]
    private let pacer: (@Sendable () -> @Sendable (Int) async throws -> Void)?   // called once per chunks(); returns "wait until sample index i is due"
    private let continuation = OSAllocatedUnfairLock<AsyncThrowingStream<Chunk, Error>.Continuation?>(initialState: nil)

    public convenience init(url: URL, id: SourceID, tag: String) throws { try self.init(url, id, tag, nil) }
    public convenience init<C: Clock<Duration>>(url: URL, id: SourceID, tag: String, clock: C) throws {
        try self.init(url, id, tag) {
            let start = clock.now
            return { i in try await clock.sleep(until: start.advanced(by: .seconds(Double(i) / Double(Chunk.sampleRate)))) }
        }
    }
    private init(_ url: URL, _ id: SourceID, _ tag: String, _ pacer: (@Sendable () -> @Sendable (Int) async throws -> Void)?) throws {
        self.id = id; self.tag = tag; self.pacer = pacer
        samples = try AudioConverter().resampleAudioFile(url)      // the same call the FluidAudio CLI makes
    }
    public func chunks() -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { c in
            continuation.withLock { $0 = c }
            let task = Task {
                do {
                    let wait = pacer?()
                    for lo in stride(from: 0, to: samples.count, by: VadManager.chunkSize) {   // 4096 = the VAD's chunk grid
                        try Task.checkCancellation()
                        try await wait?(lo)
                        c.yield(Chunk(samples: Array(samples[lo..<min(lo + VadManager.chunkSize, samples.count)]), index: lo))
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }       // after stop() the stream is already finished, so this is a no-op
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    public func stop() { continuation.withLock { $0?.finish() } }
}
```
Absolute pacing (sleep until `start + i/16000`) is required: relative sleeps add overshoot every chunk, and S4's real-time bounds would drift by about 0.4% of run time.

### `Sources/TECore/Line.swift`
```swift
public struct Line: Codable, Equatable, Sendable {
    public var t: Date            // wall clock at commit; written ISO-8601 with ms
    public var src: SourceID
    public var tag: String
    public var spk: Int
    public var text: String
    public var start: Double, end: Double     // seconds on the source's sample clock
    public init(t: Date, src: SourceID, tag: String, spk: Int, text: String, start: Double, end: Double) { ... }
}
```
All fields non-optional, so decoding a line with a missing field throws.

### `Sources/TECore/TranscriptStore.swift`
```swift
import Foundation
public actor TranscriptStore {
    public nonisolated let file: URL
    private let handle: FileHandle
    private var lines: [Line] = []
    private static let isoMs = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { d, enc in var c = enc.singleValueContainer(); try c.encode(d.formatted(isoMs)) }
        return e
    }()
    public init(paths: Paths, start: Date = Date()) throws {
        try FileManager.default.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
        file = paths.transcripts.appending(path: start.formatted(Self.isoMs) + ".jsonl")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileWriteFileExists) }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try FileHandle(forWritingTo: file)
    }
    public func append(_ line: Line) throws {
        try handle.write(contentsOf: Self.encoder.encode(line) + [0x0A])    // one write per line
        lines.append(line)
    }
    public func snapshot() -> [Line] { lines }
}
```
One engine start = one store; a second store with the same `start` throws instead of merging two engines' lines into one file (illegal state made unrepresentable). The actor serializes `append`, so a line is one `write` and `lines` equals the file's lines in order. Static properties in an actor-isolated type: mark `nonisolated(unsafe)`/plain `static let` (Sendable `JSONEncoder` use is read-only after init; Swift 5 mode accepts it).

### `Sources/TECore/Transcriber.swift`
```swift
import FluidAudio
public actor Transcriber {
    private let asr: AsrManager
    private init(_ asr: AsrManager) { self.asr = asr }
    public static func load() async throws -> Transcriber {
        let version = AsrModelVersion.ultra
        // The FluidAudio CLI builds this exact config; the oracle test compares against that CLI.
        let asr = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize))
        try await asr.loadModels(try await AsrModels.downloadAndLoad(version: version))
        return Transcriber(asr)
    }
    public func transcribe(_ samples: [Float]) async throws -> ASRResult {
        // FluidAudio rejects audio under 0.3 s; shorter segments are padded with silence.
        let short = max(0, ASRConstants.minimumRequiredSamples(forSampleRate: Chunk.sampleRate) - samples.count)
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)    // fresh state per call, as the CLI does
        return try await asr.transcribe(samples + [Float](repeating: 0, count: short), decoderState: &state)
    }
}
```
Returns `ASRResult` so S3 reads `tokenTimings` with no signature change. Actor reentrancy between the two awaits is harmless: `AsrManager` is itself an actor and each call owns its state.

### `Sources/TranscribeEverything/main.swift`
```swift
import FluidAudio
import Foundation
import TECore

guard CommandLine.arguments.dropFirst().elementsEqual(["prefetch"]) else {
    FileHandle.standardError.write(Data("usage: TranscribeEverything prefetch\n".utf8)); exit(2)
}
_ = try await Transcriber.load()          // downloads Ultra and pays the one-time ANE compile
_ = try await VadManager()                // downloads Silero VAD
_ = try await DiarizerModels.download()   // downloads WeSpeaker
print("models ready")
```
Later strata add subcommands to this one executable.

## Scripts

### `setup.sh`
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift run -c release TranscribeEverything prefetch
```

### `test-setup.sh` (test-only tooling)
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
C="$HOME/Library/Caches/transcribe-everything"
swift package resolve
swift build -c release --product fluidaudiocli --package-path .build/checkouts/FluidAudio --scratch-path "$C/fluidaudiocli-build"
uv run --no-project fixtures.py "$C" "$C/fluidaudiocli-build/release/fluidaudiocli"
```
Python runs from the repo root; downloads land only under `$C/downloads`, nothing is run from there.

### `fixtures.py`
PEP 723 header: `requires-python = ">=3.12"`, dependencies `soundfile numpy pyarrow requests`. Args: `cache cli`. `F = cache/"fixtures"`. Every stage skips if its output exists (idempotent). Stages:

1. **LibriSpeech.** Download `https://www.openslr.org/resources/12/test-clean.tar.gz` to `cache/downloads/test-clean.tar.gz` if missing (urllib, streamed to a `.part` file, renamed when complete). Stream-extract with `tarfile.open(path, "r|gz")` only members under `LibriSpeech/test-clean/{4970,4992,5105}/` into `cache/downloads/librispeech/`, using `extractall(filter="data")`. `SPEAKERS = ["4970","4992","5105"]` (sorted indices 20–22; comment says so).
2. **conversation / turns / continuous.** Port of `spike/make_fixtures.py`, minus the three `embed*` sets (spike threshold selection only), with `speakers` replaced by `SPEAKERS`: `utterances(spk)` and `trim()` verbatim; `continuous` from `SPEAKERS[0]`, `list(utterances)[4:]`, 0.15 s gaps until > 40 s; `conversation` = first 4 utterances of each speaker, round-robin, 0.8 s gaps. Outputs `F/conversation.wav`, `F/conversation.json`, `F/continuous.wav`, `F/continuous.json`. Then, verbatim from `scratch/oracle.py`: `F/turns/NN.wav` = `audio[int(t["start"]*sr):int(t["end"]*sr)]` written `subtype="FLOAT"` (NN = `%02d`, 12 turns). `assert len(turn) < 480_000` for each turn (see Uncertainty 3).
3. **AMI.** Download `https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Mix-Headset.wav` and `https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/test/ES2004a.rttm` to `cache/downloads`. `F/ami.wav` = first 900 s (`sf.read(frames=900*16000, dtype="int16")`, written PCM_16, assert sr == 16000). `F/ami.rttm` = RTTM rows with onset < 900, durations clipped to end at 900. (900 s is the length the S3 numbers were measured on: `spike/sustain_probe.sh`.)
4. **VoxConverse.** Logic of `/tmp/vox2.py`: GET `https://huggingface.co/api/datasets/diarizers-community/voxconverse`, `files` = siblings whose `rfilename` ends `.parquet` and contains `"test"`, in listed order; for each, GET `https://huggingface.co/datasets/diarizers-community/voxconverse/resolve/main/<f>`, `pq.read_table(io.BytesIO(bytes)).to_pylist()`; per row `n = len(set(r["speakers"]))`, `dur = max(r["timestamps_end"])`; if `n in (2,3,4,6,9)`, `n` not yet taken, `120 < dur < 900`: `a, sr = sf.read(io.BytesIO(r["audio"]["bytes"]))`, write `F/vox{n}.wav` (`sf.write(path, a, sr)`) and `F/vox{n}.rttm` with lines `SPEAKER vox{n} 1 {s:.3f} {e-s:.3f} <NA> <NA> {spk} <NA> <NA>`; stop at five. Then assert each clip's duration matches Uncertainty 12 within 1.0 s and `sr == 16000`, and the RTTM speaker count equals `n`: S3's bounds were measured on these clips, so a different HF listing fails here, not in S3.
5. **Oracle.** For each `F/turns/NN.wav` without `F/oracle/NN.json`: `subprocess.run([cli, "transcribe", wav, "--model-version", "ultra", "--output-json", out], check=True)`. The JSON keeps `text` and `wordTimings` (S2 uses the word times).

### `test.sh` (the one suite entry; filters only)
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
out="$PWD/test-results/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$out"
TE_RESULTS="$out" swift test -c release --parallel --num-workers 1 --xunit-output "$out/xunit.xml" ${1:+--filter "$1"} 2>&1 | tee "$out/log.txt"
echo "results: $out"
```
`pipefail` carries `swift test`'s exit code through `tee`. `--parallel` is only there because XCTest xunit needs it (Uncertainty 6); `--num-workers 1` keeps runs serial so timing tests (S4+) never contend.

## Tests

All XCTest, `import XCTest`, `@testable` never used. Temp roots: `FileManager.default.temporaryDirectory.appending(path: "te-" + UUID().uuidString)`, removed in `addTeardownBlock`.

### `Support.swift`
```swift
enum Fixtures {
    static let dir = ~/Library/Caches/transcribe-everything/fixtures
    struct Turn: Decodable { let speaker: String; let start, end: Double; let text: String }
    static func turns() throws -> [Turn]                 // decodes conversation.json
    static func turnWav(_ i: Int) -> URL                 // turns/%02d.wav
    static func oracleText(_ i: Int) throws -> String    // JSONSerialization of oracle/%02d.json ["text"]
}
func normalize(_ s: String) -> [String]     // lowercase; every char outside a-z and ' becomes a space; split on whitespace
func wer(ref: String, hyp: String) -> (errors: Int, words: Int)   // word-level Levenshtein distance over normalize(); words = normalize(ref).count
func resultsDir() -> URL                     // $TE_RESULTS; XCTFail + fatalError("run ./test.sh") if unset
func collect(_ source: some AudioSource) async throws -> [Chunk]   // for try await in chunks()
```
A missing fixtures directory calls `XCTFail("run ./test-setup.sh")` and stops (no skip).

### `StoreTests` (category Store)
1. `testAppendedLinesLandInTheFileInTheDocumentedShape`. Setup: `Paths(root: tmp)`, `start = Date(timeIntervalSince1970: 1_700_000_000.5)`. Append three lines: `Line(t: Date(timeIntervalSince1970: 1_700_000_001.25), src: "mic", tag: "Mic", spk: 1, text: "He said \"hi\"\nthen left, é", start: 0.5, end: 2.25)` and two others with different values in every field. Assertions: (a) `store.file.lastPathComponent == "2023-11-14T22:13:20.500Z.jsonl"` and its directory is `tmp/transcripts`; (b) read the file as UTF-8, split on `\n`, exactly 3 non-empty lines and the text ends with `\n`; (c) per line `JSONSerialization` gives a dictionary whose key set is exactly `{t, src, tag, spk, text, start, end}` and whose values equal the inputs (`t` string `"2023-11-14T22:13:21.250Z"`, `src` the string `"mic"`, numbers as Double/Int); (d) `await store.snapshot() == appended`. (e) reload round-trip: each file line decoded with a test-local `JSONDecoder` (ISO-8601 with ms) equals the appended `Line`; removing `spk` makes decoding throw. The expectations are literals and the parse is independent of `Line`'s coding. Mutations: drop the trailing newline (b red); rename `spk` key (c red); swap `start`/`end` (c red); write `t` without fractions (a/c red).
2. `testSecondInstanceMakesANewFileAndNeverReusesOne`. Starts `s` and `s + 1`: two distinct files; append to A then B; A holds only A's lines. A third `TranscriptStore(paths:, start: s)` throws. Mutation: remove the existence check ⇒ the third construction does not throw ⇒ red.
3. `testEightConcurrentAppendersKeepEveryLineIntact`. `withThrowingTaskGroup` of 8 tasks, task `k` appends 100 lines with `text = "k\(k)-n\(n)"` and unique `start = Double(k*100+n)`. After: file has exactly 800 `\n`-terminated lines, each parses with `JSONSerialization`, the set of `text` values equals the 800 expected, and `snapshot().count == 800`. Mutation: make the store a non-isolated `final class` writing the JSON and `"\n"` in two `write` calls ⇒ torn or duplicated lines ⇒ red.

### `SourcesTests` (category Sources)
Uses `turns/00.wav` (3.03 s ⇒ 12 chunks of 4096).
1. `testChunksTileTheFileOnTheVadGrid`. `collect(FileSource(url:…))`; let `n = AVAudioFile(forReading: url).length` (independent of `AudioConverter`; the wav is already 16 kHz). Assert `chunks[k].index == k * 4096`, all but the last have 4096 samples, the last has 1…4096, and `sum(samples.count) == n`. Mutation: drop every 10th chunk ⇒ index and total fail ⇒ red.
2. `testPacedSourceIsNeverEarlyAndNeverDrifts`. `FileSource(…, clock: ContinuousClock())`; record `t0 = ContinuousClock.now` before iterating, and each chunk's elapsed seconds. Assert `elapsed ≥ Double(index)/16000 − 0.02` for every chunk (0.02 s = scheduling jitter allowance, the no-pacing mutant is up to 2.8 s early) and the last chunk's elapsed ≤ its due time + 0.256 (one chunk: relative-sleep drift over 12 chunks would also stay small, the bound only guards against a stalled schedule). Mutation: delete the `try await wait?(lo)` line ⇒ early ⇒ red.
3. `testStopEndsTheStreamEarly`. Paced source; read the first chunk, call `stop()`, keep iterating until the stream ends; assert the loop ends and the total received is `< 12`. Mutation: `stop()` empty ⇒ all 12 arrive ⇒ red.

### `OracleTests` (category Oracle)
1. `testEveryTurnIsTextIdenticalToTheFluidAudioCLI`. `let tr = try await Transcriber.load()`. For i in 0..<12: `src = FileSource(url: Fixtures.turnWav(i), id: SourceID(rawValue: "turn\(i)"), tag: "t")`; `samples = try await collect(src).flatMap(\.samples)`; `XCTAssertLessThan(samples.count, 480_000)`; `ours = try await tr.transcribe(samples).text`; `XCTAssertEqual(ours, try Fixtures.oracleText(i))` (exact string); `(e, w) = wer(ref: truth[i].text, hyp: ours)`. After the loop: `XCTAssertEqual(Σe, 6)` and `XCTAssertEqual(Σw, 242)` (DECISIONS: oracle WER on these turns; this also pins `wer`/`normalize` and the fixtures). Write `resultsDir()/oracle.md`: a markdown table `| turn | truth | ours | errors/words |` plus a final `corpus` row. The oracle text was produced by the CLI binary, the comparison by our path; nothing is shared except FluidAudio. Mutations: (i) FileSource drops every 10th chunk ⇒ text differs ⇒ red; (ii) in `Transcriber.load`, use `.v3` ⇒ red. Using `ASRConfig.default` is not a mutant: it is value-identical (Uncertainty 1).
2. `testAudioUnderPointThreeSecondsIsPaddedNotRejected`. `try await tr.transcribe([Float](repeating: 0, count: 1600))` returns without throwing (0.1 s of silence). Mutation: remove the padding ⇒ `ASRError.invalidAudioData` ⇒ red.
3. `testWerOnKnownCases`. `wer(ref: "The cat, sat!", hyp: "the dog sat")` is `(1, 3)`; `wer(ref: "it's", hyp: "its")` is `(1, 1)` (apostrophe kept); `wer(ref: "a b", hyp: "")` is `(2, 2)`. Mutation: strip apostrophes in `normalize` ⇒ second case red.

## Attaining the result (in order, each is a command Minh can rerun)

1. `./setup.sh` ⇒ prints `models ready`, exit 0 (idempotent; models are already cached on this machine).
2. `./test-setup.sh` ⇒ builds `fluidaudiocli` (~100 s first time), builds fixtures, records 12 oracle files under `~/Library/Caches/transcribe-everything/fixtures/oracle/`.
3. `./test.sh` ⇒ all green; prints `results: test-results/<timestamp>`.
4. `cat test-results/<timestamp>/oracle.md` ⇒ the human-verifiable table of 12 turns: truth, our text, errors/words, corpus row `6/242`.
5. Mutation pass before commit: apply each listed mutant by hand, run `./test.sh <Class>` (filter only), confirm red, `git checkout -- <file>`, confirm green. Record the red/green pairs in the commit message.

## Not in this stratum
Change streams on the two stores, provisional tails, Transcriber priority, SourcePipeline/Engine/SingleSpeaker, `build.sh`, any CLI beyond `prefetch`.
