# Stratum 14 Blueprint — Config live, font size

Builds on S1–S13 as built or blueprinted. Ground truth read: `Config.swift` and `ConfigStore` (S1, in the repo), the only reads of `config.current` (`SourcePipeline.swift:31,90,111`), `Engine.swift`, `PipelineSupport.swift:makeEngine`, `Render.swift`, S7's `eventually`, S9's `Session(config:)`, S11's `Overlay` (subscribes to `config.changes()`) and `OverlayRig(_:config:)`, S10's `MenuBar(settings:)`.

# Uncertainties squashed

1. **Directory watching.** Probe `scratch/s14-probe/probe.swift` (a dispatch source on the directory vs FSEvents on the directory, `config.json` in it): create, in-place truncate+write, atomic rename (`Data.write(.atomic)`), an unrelated file, delete.
   - The dispatch source (`.write`) fired for create, atomic rename, unrelated file and delete, and **did not fire for the in-place overwrite**. A source on the file descriptor would miss the atomic rename (the descriptor keeps the old inode).
   - FSEvents (latency 0.05 s, `NoDefer`) fired for **all five** within 12 ms ⇒ `DirectoryWatcher` uses FSEvents on the directory; an editor that saves in place (`echo >`, nano) and one that renames (vim) both work. 0.05 s only coalesces a truncate+write pair into one reload (events arrived at ≤ 12 ms).
   - FSEvents also fires for unrelated files and for changes under `transcripts/` (the config sits in the data root). `reload` publishes only a change of `(config, error)`, so those cost one tiny read.
   - The callback ignores its `paths` argument: without `kFSEventStreamCreateFlagUseCFTypes` it is a `char **`; casting it to `NSArray` segfaulted the first probe (exit 139).
2. **`ClosedRange<Int>` is Codable as `[lo, hi]`** (encodes `[12,48]`). Decoding `[48,12]` throws "Cannot initialize ClosedRange<Int> with a lowerBound (48) greater than upperBound (12)" under coding path `fontSizeRange`.
3. **The `ConfigStore` and `DirectoryWatcher` below were compiled and run** (`scratch/s14-probe/{Config,DirectoryWatcher,main}.swift`, `swiftc -O -swift-version 5`, no FluidAudio): defaults written on first run; in-place, atomic and delete+create edits each seen; seven invalid files each kept the previous value with a reason; recovery after a valid rewrite; two `changes()` subscribers both woken by one `set`; `set` out of range throws; `set` on an invalid file throws and leaves the file untouched. `FontSizeItem` was compiled with them and driven. The code below is that code.
4. **Synthesized `Decodable` requires every key**, even ones with defaults (removing `minSilence` ⇒ `keyNotFound`). The written file always carries all ten keys and a file missing one is invalid. Decision (DECISIONS, written): no partial config files, no per-key defaults.
5. **Where config is read.** Only `SourcePipeline.swift:31` (run start), `:90` (every VAD start event) and `:111` (after a force-cut). `minSilence` enters `VadSegmentationConfig` per chunk from `cfg`, so an edit changes `minSilence` for the **next segment** of a running source with no code change. Speaker settings and `maxSegment` likewise. `render` takes `config` per call; `Overlay.draw` reads `config.current` per draw and redraws on `changes()` (S11).
6. **`ConfigStore` keeps `current` as a stored property**, so every reader compiles unchanged; `ConfigStore()` (in memory, no file) stays for `makeEngine`, `verify`'s `AppController.start` and the earlier tests. `set` becomes `throws`; no caller outside `Config.swift` exists (grep).
7. **`changes()` returns a fresh stream per call** (S1 deferral 13): one stored `AsyncStream` would split elements between its consumers (the font item and the overlay).
8. **Menu slider.** `NSMenuItem.view` takes any `NSView`; an `NSSlider` in it receives mouse tracking from the menu. A real menu drag cannot be driven here, so it is Minh's gate; in-process the action is sent with `sendAction`. Snapping is in the action (`doubleValue.rounded()`); no tick marks.
9. **Slider echo.** A drag writes at most once per integer; each write returns as a `changes()` event that would reset the thumb to an older value while the mouse is further along. `show()` leaves the thumb and value alone while the left mouse button is down (`NSEvent.pressedMouseButtons & 1`); the final write arrives after mouse-up and sets the final value.
10. **Write ordering.** Slider actions fire ~60 per second. One `AsyncStream<Int>` (`bufferingNewest(1)`) with one consuming task serializes the writes and drops superseded intermediate values, so the last value lands last.
11. **Count at 0.25.** DECISIONS: VAD segmentation alone gives 16 segments at 0.25 and the 12 turns at 0.5; S2 measured the live pipeline at 14 lines at 0.5. The live pipeline's count at 0.25 (force-cuts and speaker splits included) was **not measured**. Build step 3 measures it once and pins it.
12. **Composition.** `Session` owns the one file-backed `ConfigStore` (S9: `Session(config:)`), opened once in `main.swift`; `AppController.init` receives it. `FontSizeItem` owns its slider, value, error line and subscriptions; main passes its `item` to `MenuBar(settings:)`.

# Blueprint

Files: `Sources/TECore/{Config,DirectoryWatcher,Paths}.swift`, `Sources/TEUI/FontSizeItem.swift`, `Sources/TranscribeEverything/main.swift` (edit), `Tests/TECoreTests/{ConfigTests,PipelineSupport}.swift`. Nothing else changes.

## `Sources/TECore/Paths.swift` (add one line inside `Paths`)
```swift
public var config: URL { root.appending(path: "config.json") }
```

## `Sources/TECore/DirectoryWatcher.swift` (new)
```swift
import CoreServices
import Foundation

/// Calls `onChange` after any change in `directory` or below, including in-place writes that leave the directory's entries unchanged
/// (a dispatch source on the directory misses those; one on the file misses atomic renames).
final class DirectoryWatcher: @unchecked Sendable {
    private final class Box {
        let fire: @Sendable () -> Void
        init(_ fire: @escaping @Sendable () -> Void) { self.fire = fire }
    }
    private let stream: FSEventStreamRef
    private let box: Unmanaged<Box>

    init(_ directory: URL, onChange: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(onChange))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(
            nil, { _, info, _, _, _, _ in Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().fire() }, &context,
            [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))!
        self.box = box
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "DirectoryWatcher"))
        FSEventStreamStart(stream)
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        box.release()
    }
}
```

## `Sources/TECore/Config.swift` (full replacement)
```swift
import Foundation

public struct ConfigError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

public struct Config: Codable, Equatable, Sendable {
    // Values and their origins: DECISIONS.md.
    public var minSilence = 0.5, maxSegment = 12.0
    public var speakerThreshold = 0.35, speakerWindow = 2.0, speakerHop = 0.5, speakerConfirmWindows = 4
    public var windowSeconds = 20.0, expandedSeconds = 60.0
    public var fontSize = 22, fontSizeRange = 12...48
    public init() {}

    /// The file is the boundary: values the pipeline cannot run with (a zero hop never advances the window loop) stop here, once.
    public func validate() throws {
        func fail(_ why: String) -> ConfigError { ConfigError(description: why) }
        guard fontSizeRange.contains(fontSize) else {
            throw fail("fontSize \(fontSize) is outside fontSizeRange \(fontSizeRange.lowerBound)...\(fontSizeRange.upperBound)")
        }
        for (name, v) in [("minSilence", minSilence), ("maxSegment", maxSegment), ("speakerWindow", speakerWindow),
                          ("speakerHop", speakerHop), ("windowSeconds", windowSeconds), ("expandedSeconds", expandedSeconds)] {
            guard v > 0 else { throw fail("\(name) must be above 0") }
        }
        guard speakerConfirmWindows >= 1 else { throw fail("speakerConfirmWindows must be at least 1") }
        guard windowSeconds <= expandedSeconds else { throw fail("windowSeconds must not exceed expandedSeconds") }
    }
}

/// Single owner of settings. With a file, the file is the truth: `set` writes it and every reader sees what a reload of it yields.
public actor ConfigStore {
    public private(set) var current: Config
    /// Why the file is not in use; nil while it is valid. `current` keeps the last valid value.
    public private(set) var error: String?
    private let file: URL?
    private var watcher: DirectoryWatcher?
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// In memory, no file.
    public init(_ initial: Config = Config()) {
        current = initial
        file = nil
    }

    private init(file: URL) {
        current = Config()
        self.file = file
    }

    /// Writes the defaults on first run, then loads and watches the file. An invalid file does not throw: defaults run and `error` says why.
    public static func open(file: URL) async throws -> ConfigStore {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { try encode(Config()).write(to: file, options: .atomic) }
        let store = ConfigStore(file: file)
        await store.start(watching: file.deletingLastPathComponent())
        return store
    }

    /// Yields after every change of `current` or `error`; a reader redraws from them, so only "changed" matters. One stream per caller.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        return stream
    }

    public func set(_ new: Config) throws {
        try new.validate()
        guard let file else { return apply(new, nil) }
        if let error { throw ConfigError(description: "config.json is invalid (\(error)); fix it first") }
        try Self.encode(new).write(to: file, options: .atomic)
        reload()
    }

    private func start(watching directory: URL) {
        // Watching starts before the first load, so an edit in between is not lost.
        watcher = DirectoryWatcher(directory) { [weak self] in Task { await self?.reload() } }
        reload()
    }

    private func reload() {
        guard let file else { return }
        do {
            let c = try JSONDecoder().decode(Config.self, from: Data(contentsOf: file))
            try c.validate()
            apply(c, nil)
        } catch { apply(current, Self.reason(error)) }
    }

    private func apply(_ c: Config, _ e: String?) {
        guard (c, e) != (current, error) else { return }
        (current, error) = (c, e)
        for s in subscribers.values { s.yield() }
    }

    private func drop(_ id: UUID) { subscribers[id] = nil }

    private static func encode(_ c: Config) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(c)
    }

    private static func reason(_ error: Error) -> String {
        guard let d = error as? DecodingError else { return "\(error)" }
        switch d {
        case .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            return (c.codingPath.map(\.stringValue) + [c.debugDescription]).joined(separator: " ")
        @unknown default: return "\(d)"
        }
    }
}
```
`set` refuses while the file is invalid (it would overwrite the user's unfinished edit with the last valid values). An unreadable or deleted file is also "invalid" and surfaces its reason; a deleted file is not recreated.

## `Sources/TEUI/FontSizeItem.swift`
```swift
import AppKit
import TECore

/// The font-size menu row: an integer slider over fontSizeRange, its value, and the config file's error when it is invalid.
@MainActor
public final class FontSizeItem: NSObject {
    public let item = NSMenuItem()
    private let slider = NSSlider(), value = NSTextField(labelWithString: ""), problem = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let config: ConfigStore
    private let sizes = AsyncStream<Int>.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))

    public init(config: ConfigStore) async {
        self.config = config
        super.init()
        let title = NSTextField(labelWithString: "Font size")
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.alignment = .right
        value.identifier = NSUserInterfaceItemIdentifier("fontSize.value")
        problem.identifier = NSUserInterfaceItemIdentifier("fontSize.error")
        problem.textColor = .systemRed
        problem.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problem.maximumNumberOfLines = 0
        problem.preferredMaxLayoutWidth = 208
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        let row = NSStackView(views: [title, value])
        stack.setViews([row, slider, problem], in: .leading)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        NSLayoutConstraint.activate([row.widthAnchor.constraint(equalToConstant: 208), slider.widthAnchor.constraint(equalToConstant: 208)])
        item.view = stack
        let changes = await config.changes()
        let values = sizes.stream
        await show()
        Task { [weak self] in for await _ in changes { await self?.show() } }
        Task { [weak self] in for await v in values { await self?.write(v) } }
    }

    private func show(_ failure: String? = nil) async {
        let c = await config.current, stored = await config.error
        let e = failure ?? stored
        slider.minValue = Double(c.fontSizeRange.lowerBound)
        slider.maxValue = Double(c.fontSizeRange.upperBound)
        if NSEvent.pressedMouseButtons & 1 == 0 {
            slider.doubleValue = Double(c.fontSize)
            value.stringValue = "\(c.fontSize)"
        }
        problem.stringValue = e.map { "config.json: \($0)" } ?? ""
        problem.isHidden = e == nil
        stack.frame.size = stack.fittingSize
    }

    @objc private func moved() {
        let v = Int(slider.doubleValue.rounded())
        slider.doubleValue = Double(v)
        value.stringValue = "\(v)"
        sizes.continuation.yield(v)
    }

    private func write(_ size: Int) async {
        var c = await config.current
        guard c.fontSize != size else { return }
        c.fontSize = size
        do { try await config.set(c) } catch { await show("\(error)") }
    }
}
```
Layout constants (208, 16, 4) are layout only; Minh's gate confirms them. Driven in the probe against a real `ConfigStore`: min/max 12/48, value "22", error hidden, view 240×48; action at 30.6 ⇒ thumb 31, label "31", file 31; six back-to-back actions ⇒ file 25, thumb 25 after 0.3 s; a file missing `minSilence` ⇒ error shown, view grows to 240×70.

## `Sources/TranscribeEverything/main.swift` (edit the `case nil:` arm; final text in S15)
Add `let paths = Paths()` first; replace `let config = ConfigStore()` by `let config = try await ConfigStore.open(file: paths.config)`; the `Session(...)` call gains `paths: paths`; add `let fontSize = await FontSizeItem(config: config)`; `MenuBar(..., settings: [overlay.hideShowItem, fontSize.item])`; `fontSize` joins the `withExtendedLifetime` tuple.

## `Tests/TECoreTests/PipelineSupport.swift` (edit `makeEngine`)
Signature becomes `makeEngine(_ root: URL, config: ConfigStore = ConfigStore())` and passes `config` to `Engine`. No other change.

## `Tests/TECoreTests/ConfigTests.swift` (class `ConfigTests`, category Config)
Helpers (test-local; expected values are literals, none from the code under test):
```swift
private let base: [String: Any] = ["minSilence": 0.5, "maxSegment": 12.0, "speakerThreshold": 0.35, "speakerWindow": 2.0, "speakerHop": 0.5,
    "speakerConfirmWindows": 4, "windowSeconds": 20.0, "expandedSeconds": 60.0, "fontSize": 22, "fontSizeRange": [12, 48]]
private func json(_ edits: [String: Any] = [:]) -> Data   // base.merging(edits); a value of NSNull removes the key; JSONSerialization
private enum Style: CaseIterable { case inPlace, atomic, replace }
private func write(_ data: Data, _ file: URL, _ style: Style) throws
  // inPlace: FileHandle(forWritingTo:) truncate(atOffset: 0), write, close. atomic: data.write(to:, options: .atomic). replace: removeItem then data.write(to:)
private func open(_ test: XCTestCase) async throws -> (ConfigStore, URL)   // temporaryRoot, ConfigStore.open(file: Paths(root:).config)
private func fires(_ s: AsyncStream<Void>, within seconds: Double = 5) async -> Bool
  // task group: one task `var it = s.makeAsyncIterator(); return await it.next() != nil`, one `sleep; return false`; first result wins, cancelAll
private func onDisk(_ file: URL) throws -> [String: Any]   // JSONSerialization of the file
```
`eventually` (S7) is the only wait; the one fixed sleep is `fires`' negative window.

1. **`testFirstRunWritesTheDefaultsFileAndLoadsIt`.** Open on an empty temp root. `onDisk(file)` has exactly the ten keys of `base` and every value equals `base`'s (`NSDictionary` equality). `current`: `fontSize == 22`, `minSilence == 0.5`, `fontSizeRange == 12...48`; `error == nil`. Mutants: skip writing the file ⇒ `onDisk` throws ⇒ red; write only some keys ⇒ key-set assertion red.
2. **`testEditsAreSeenWhetherInPlaceAtomicOrReplaced`.** Open. For (style, n) over `Style.allCases` with n = 30, 31, 32: `write(json(["fontSize": n, "minSilence": 0.25]), file, style)`; `eventually` `current.fontSize == n`; `current.minSilence == 0.25`, `error == nil`. Mutants (swap `DirectoryWatcher` for): a dispatch source on the directory ⇒ the in-place round never arrives ⇒ red; one on the file descriptor ⇒ atomic round red; no watcher ⇒ all red.
3. **`testInvalidEditsKeepThePreviousValueAndShowTheReason`.** Open; write `json(["fontSize": 30])`, wait for 30; `before = await store.current`. Table `(data, expected substring)`: `Data("{".utf8)` — `"not valid JSON"`; `json(["fontSize": 99])` — `"fontSize"`; `json(["fontSizeRange": [48, 12]])` — `"fontSizeRange"`; `json(["minSilence": NSNull()])` — `"minSilence"`; `json(["speakerHop": 0.0])` — `"speakerHop"`; `json(["windowSeconds": 90.0])` — `"windowSeconds"`; `json(["fontSize": "big"])` — `"fontSize"`. For each: `write(data, file, .atomic)`; `eventually` `error != nil`; `error` contains the substring; `current == before`; then `write(json(["fontSize": 30]), …)`, `eventually` `error == nil`. Mutants: on failure set `current = Config()` ⇒ red; drop `validate()` ⇒ the 99, hop 0 and window rows red; `reason` returns `""` ⇒ substring red.
4. **`testSetWritesTheFileAndRefusesOutOfRangeAndInvalidFiles`.** Open. `c = current; c.fontSize = 40`; `try await set(c)`. `onDisk["fontSize"] as? Int == 40`, `onDisk["minSilence"] as? Double == 0.5`, `current.fontSize == 40`. `c.fontSize = 50` ⇒ `set` throws and `Data(contentsOf: file)` is byte-identical to before. Write `Data("{".utf8)` in place, `eventually` `error != nil`; `c.fontSize = 20` ⇒ `set` throws with a message containing `"invalid"`; the file still reads `{`. Mutants: `set` skips `validate` ⇒ the 50 row red; `set` writes while invalid ⇒ the last row red; `set` updates `current` without writing ⇒ `onDisk` red.
5. **`testEachSubscriberGetsEveryChangeAndAnUnchangedSetPublishesNothing`.** Open; `a = await store.changes()`, `b = await store.changes()`. `set(c with fontSize 33)` ⇒ `fires(a)` and `fires(b)` both true. `set` the same config again ⇒ `fires(a, within: 0.5)` false (the watcher's own reload of the same file is also silent). Mutants: one shared stream ⇒ the second `fires` false ⇒ red; `apply` without the equality guard ⇒ the last assertion red.
6. **`testRenderFollowsTheFileForWindowSeconds`.** Open. `now = Date()`; one `Line(t: now − 30, src: "a", tag: "A", spk: 1, text: "old line.", start: 0, end: 1)`; `Snapshot(lines: [line], tails: [], speakers: ["a": [1]])`. `render(snapshot:attached: ["a"], now: now, expanded: false, config: await store.current).rows.map(\.text) == []` (30 s > 20 s). Write `json(["windowSeconds": 40.0])` in place, `eventually` `current.windowSeconds == 40`; render again ⇒ `["old line."]`. Mutant: render reads `Config()` instead of the argument ⇒ red.
7. **`testFontSizeSliderSnapsToIntegersWritesTheFileAndFollowsEdits`** (`@MainActor`, `_ = NSApplication.shared`). `s = await FontSizeItem(config: store)`; find views in `s.item.view!` by recursive walk: the `NSSlider`, and text fields by identifier `fontSize.value` / `fontSize.error`.
   - Range: `slider.minValue == 12`, `maxValue == 48`; label `"22"`; error field hidden.
   - Snap: `slider.doubleValue = 30.6; _ = slider.sendAction(slider.action, to: slider.target)` ⇒ `slider.doubleValue == 31`, label `"31"`; `eventually` `onDisk["fontSize"] as? Int == 31`. Mutant: `Int(doubleValue)` (truncate) ⇒ 30 ⇒ red.
   - Drag: for v in 20…25: set `doubleValue = v` and send the action back to back ⇒ `eventually` file fontSize 25; after 0.3 s still 25 (last write last).
   - Follows the file: write `json(["fontSize": 18])` in place ⇒ `eventually` slider 18 and label `"18"`. Mutant: the item never calls `changes()` ⇒ red.
   - Error: write `json(["fontSize": 99])` ⇒ `eventually` error field visible containing `"fontSize"`; slider still 18; send the action with 30 ⇒ file bytes unchanged and the error still visible; write valid ⇒ error hidden.
8. **`testOverlayFontFollowsTheFile`** (`@MainActor`). `(store, file) = open`; `rig = OverlayRig(self, config: store)`; `rig.attached = {A}`; `say("A","Hello there.")`; `eventually` the first character's font size is 22 (`text.textStorage!.attribute(.font, at: 0, …)`). `write(json(["fontSize": 31]), file, .atomic)`; `eventually` it is 31. Mutant: the overlay does not subscribe to `changes()` ⇒ red.
9. **`testMinSilenceEditReachesTheRunningEngine`** (real Ultra, VAD, WeSpeaker; `Models`). `config = try await ConfigStore.open(file: Paths(root: root).config)`; `(engine, store) = try await makeEngine(root, config: config)`; `turns = Fixtures.turns()`. Attach `FileSource(url: conversationWav, id: "a", tag: "A")`, `awaitEnds(engine, 1)`. `linesA` = lines with src "a"; `segA = linesA.count − splits(linesA) { turnOf($0, turns) }` must equal **14** (S2's assertion). Then `write(json(["minSilence": 0.25]), file, .atomic)`, `eventually` `config.current.minSilence == 0.25`; attach `"b"` on the same wav, `awaitEnds(engine, 1)`; `segB` likewise. Assert `segB == minSilence025Segments` (a `let` in the test file) and `segB > segA`. Write both counts and per-source line counts to `config.md` in `resultsDir()`. Mutants: `Engine` copies the config at init ⇒ `segB == 14` ⇒ red; no watcher ⇒ the `eventually` times out ⇒ red.

Allowance: tests 1–8 a few seconds each; test 9 two unpaced conversation runs (S2's allowance + 120 s).

## Steps to attain the human-verifiable result
1. `swift build` after each file; fix compile errors only in form, never in the behaviour listed above.
2. `./test.sh Config` under pacemaker: tests 1–8 first, then 9.
3. **Pin the count.** The first run of test 9 reports `segB`. `minSilence025Segments` starts at **16** (DECISIONS: VAD segments at 0.25). If the run reports another number, that number replaces 16 and the parent records "S14 measured: segments at minSilence 0.25 = N" in DECISIONS; the test then passes only on that exact value.
4. Mutants of tests 2–5, 7, 9 one at a time (edit, `./test.sh Config`, red, revert, green). `config.md` lands in the results folder.
5. Whole `./test.sh` once.
6. **Human gate.** `./build.sh && open ~/Applications/TranscribeEverything.app`; attach an app (S10) playing speech, open the menu, drag the Font size slider: captions resize live and the thumb snaps to whole numbers. In an editor set `windowSeconds` to 5 in `~/.transcribe-everything/config.json` and save: older captions leave sooner. Break the JSON: the menu shows the red reason under the slider and the captions keep their size; fix it and the reason clears.

## Not in S14
Persisting attach state or any setting other than the config file; a menu control for any setting but font size; recreating a deleted config file; per-key defaults; a config schema document.
