# Stratum 9 Blueprint — Status item, auto-start, lifecycle

Builds on S1–S8 as built or blueprinted: `Engine` (`attach`, `detach`, `ended`), `TranscriptStore`, `ConfigStore`, `FileSource(url:id:tag:clock:)`, `FailingSource(base:failAt:)` (PipelineSupport), S6's `AppController.start(paths:)` and `Verify`, S7's `AppSource(pid:id:tag:stallLimit:)` and `eventually`, S8's `MicSource(id:)`.

This stratum fixes the app's single composition root (final form in the S15 blueprint, `main.swift`) and the names every later stratum uses: `Session`, `Target`, `EngineState`, `Permissions`, `AppController(paths:models:config:)`, `Row`, `MenuBar`, `Rig`.

# Uncertainties squashed

1. **AppKit facts.** `statusItem(withLength:)`, `item.button`, `item.menu` (`spike/Sources/Probe/main.swift:374-381`); preflight and request calls (`:465-471`). Probed (`/tmp/te-s9-probe/main.swift`, no status item): an `NSMenuItem` subclass with `target = self` fires through `menu.performActionForItem(at: menu.indexOfItem(withTitle:))`; a row with `action: nil` is a disabled label; an `NSImage(size:flipped:drawingHandler:)` drawn into an `NSBitmapImageRep` reads back at pixel (8, 8) in sRGB: `systemYellow` 1.00/0.84/0.00, `systemGreen` 0.19/0.82/0.35, `systemGray` 0.60/0.60/0.62.
2. **One writer of the engine.** `Engine.attach` has one running source per id (precondition, `Engine.swift:30`) and suspends inside (`await store.epoch`), so a `detach` interleaved with an `attach` of one id could no-op and leave an untracked source. `finish` clears `running[id]` then yields `SourceEnd` (`:53-55`) inside the pipeline task, so `detach` (`:50`) returns after the end event is yielded. Every engine mutation therefore goes through `Session.serial`, one task chain; `Session.applied` (ids the engine owns) is the mark. A natural end removes the id from `applied`; a user detach removed it first, so `sourceEnded` routes on `applied.remove(id) != nil` and never re-derives the cause. `Engine.deinit` ends the latency activity: dropping the core at Stop releases it.
3. **Stop during starting = task cancellation.** `Transcriber.load()` (an 11 s Core ML compile) is not cancellable, so `boot` checks `Task.checkCancellation()` after the load, before any store or engine exists. Loaded models are kept; the next Start does not reload.
4. **Permissions.** A grant made while the app runs may not show in this process's preflight (DECISIONS). `boot` requests only what is missing, re-reads preflight once, and fails naming what is still missing. The icon is yellow while a prompt is open. Missing permission is `failed(reason)`, not a fifth state.
5. **Names and visibility.** The test module has `enum Models` (`PipelineSupport.swift:7`), so the public bundle is `CoreModels`. `Boom` exists (`PipelineSupport.swift:69`, used as `Boom()` and `is Boom`) and is edited in place. `swift test -c release` has no `-enable-testing`, so everything tests touch is `public`; the test target gains `TEUI`.
6. **Deviation from STRATA wording.** STRATA S9 drives attach edges "by invoking the real `NSMenuItem` actions", but the Microphone and Attach rows are S10's. S9 drives them through `Session.toggle(_:)`, the one function every S10 row calls; Start, Stop and Quit use their real rows.
7. **Sources are looked up at attach time.** `Target.source` calls `NSRunningApplication.runningApplications(withBundleIdentifier:)` each time (restore included). A quit app throws `AppGone`; SCK would deliver silence for a dead pid (DECISIONS). Two instances of one bundle id resolve to the first (per-app attach, accepted).
8. **Settled at build** (a red is a finding, never loosened): (a) the status item works in the `xctest` process after `NSApplication.shared` with `.accessory` (each test shows a dot in Minh's menu bar for its length); (b) the dot colours stay inside the classifier's ranges on macOS 26; (c) menu-action `Task`s complete under `eventually` polling; (d) the top-level `var session: Session!` in `main.swift` may need `await`: add exactly what the compiler asks.

# Blueprint

New: `Sources/TEUI/{Permissions,Row,MenuBar}.swift`, `Tests/TECoreTests/{AppRig,LifecycleTests}.swift`. Rewritten whole: `Sources/TEUI/AppController.swift`. Edited: `Package.swift`, `Sources/TranscribeEverything/main.swift`, `Tests/TECoreTests/PipelineSupport.swift`. Nothing else.

## `Package.swift` (edit)
Test target dependencies become `["TECore", "TEUI", "FluidAudio"]`. No later stratum edits this file.

## `Tests/TECoreTests/PipelineSupport.swift` (edit `Boom` in place)
`struct Boom: Error, CustomStringConvertible { var description = "boom" }`. `Boom()` and `is Boom` keep working; `Boom(description: "x")` is new.

## `Sources/TEUI/Permissions.swift`
```swift
import AVFoundation
import CoreGraphics

public enum Permission: String, CaseIterable, Sendable { case microphone = "Microphone", screenRecording = "Screen Recording" }

@MainActor public protocol Permissions {
    func granted(_ p: Permission) -> Bool
    func request(_ p: Permission) async
}

public struct SystemPermissions: Permissions {
    public init() {}
    public func granted(_ p: Permission) -> Bool {
        switch p {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }
    public func request(_ p: Permission) async {
        switch p {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        }
    }
}
```
System Audio Recording has no request API and no preflight (DECISIONS); Screen Recording is what per-app capture needs. `SystemPermissions` is the one owner of these two questions; S15's `permissions` op calls it.

## `Sources/TEUI/AppController.swift` (rewrite whole; keeps `transcriber`, `engine`, `store`, `paths`, `start(paths:)` that S6–S8 use)
```swift
import AppKit
import FluidAudio
import TECore

public struct CoreModels: Sendable {
    public let transcriber: Transcriber, embedder: Embedder, vad: VadManager
    public init(transcriber: Transcriber, embedder: Embedder, vad: VadManager) { /* assign */ }
    public static func load() async throws -> CoreModels {
        async let t = Transcriber.load(); async let e = Embedder.load(); async let v = VadManager()
        return CoreModels(transcriber: try await t, embedder: try await e, vad: try await v)
    }
}

/// One engine start: a new store and engine over already loaded models and the process's one `ConfigStore`.
public final class AppController {
    public let paths: Paths, transcriber: Transcriber, engine: Engine, store: TranscriptStore
    public init(paths: Paths, models: CoreModels, config: ConfigStore) throws {
        self.paths = paths
        transcriber = models.transcriber
        store = try TranscriptStore(paths: paths)
        engine = Engine(transcriber: models.transcriber, embedder: models.embedder, vad: models.vad, store: store, config: config)
    }
    /// For `verify`: no permissions, no menu, defaults from an in-memory config so a scenario never depends on a user's file.
    public static func start(paths: Paths = Paths()) async throws -> AppController {
        try AppController(paths: paths, models: try await CoreModels.load(), config: ConfigStore())
    }
}

public enum EngineState: Equatable, Sendable { case stopped, starting, running, failed(String) }

/// What the user can attach. The id is the single identity everything routes on.
public enum Target: Equatable, Sendable {
    case mic
    case app(bundleId: String, tag: String)
    public var id: SourceID { switch self { case .mic: SourceID(rawValue: "mic"); case .app(let b, _): SourceID(rawValue: b) } }
    public var tag: String { switch self { case .mic: "Mic"; case .app(_, let t): t } }

    struct AppGone: Error, CustomStringConvertible { var description: String { "not running" } }
    /// The one place a target becomes an `AudioSource`; the pid is looked up now.
    public static func source(_ t: Target) throws -> any AudioSource {
        switch t {
        case .mic: return MicSource(id: t.id)
        case .app(let bundleId, let tag):
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.processIdentifier else { throw AppGone() }
            return AppSource(pid: pid, id: t.id, tag: tag)
        }
    }
}
```

`Session` — single owner of state, attach set, failure reasons and the engine's lifetime. No AppKit except the default `terminate`.
```swift
@MainActor public final class Session {
    public private(set) var state = EngineState.stopped { didSet { notify() } }
    public private(set) var attached: [Target] = [] { didSet { notify() } }               // checkmarks, in attach order
    public private(set) var failures: [SourceID: String] = [:] { didSet { notify() } }    // "<tag>: <reason>"; the menu and the overlay bar read this
    public private(set) var core: AppController?
    public let permissions: any Permissions, config: ConfigStore
    private let paths: Paths
    private let loader: @MainActor () async throws -> CoreModels, makeSource: @MainActor (Target) throws -> any AudioSource
    private let onStart: @MainActor (TranscriptStore) -> Void, terminate: @MainActor () -> Void
    private var models: CoreModels?, booting: Task<Void, Never>?, watcher: Task<Void, Never>?
    private var chain = Task<Void, Never> {}
    private var applied: Set<SourceID> = []       // ids the engine owns right now
    private var observers: [@MainActor () -> Void] = []

    /// `onStart` runs at every running start with the new store (main wires `overlay.bind`); no default, so a missing wire is a compile error.
    public init(paths: Paths = Paths(), permissions: any Permissions = SystemPermissions(), config: ConfigStore,
                loader: @escaping @MainActor () async throws -> CoreModels = CoreModels.load,
                makeSource: @escaping @MainActor (Target) throws -> any AudioSource = Target.source,
                onStart: @escaping @MainActor (TranscriptStore) -> Void,
                terminate: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }) { /* assign */ }

    /// Called synchronously after every change, in registration order.
    public func observe(_ f: @escaping @MainActor () -> Void) { observers.append(f) }
    private func notify() { for f in observers { f() } }

    /// Idempotent: a no-op while starting or running.
    public func start() {
        switch state {
        case .starting, .running: return
        case .stopped, .failed: break
        }
        state = .starting
        booting = Task { await boot() }
    }

    private struct Missing: Error, CustomStringConvertible {
        let names: [String]
        var description: String { "Missing permission: \(names.joined(separator: ", ")). Grant it in System Settings, then relaunch." }
    }

    private func boot() async {
        do {
            for p in Permission.allCases where !permissions.granted(p) { await permissions.request(p) }
            let missing = Permission.allCases.filter { !permissions.granted($0) }   // re-read: a grant may not be visible yet
            guard missing.isEmpty else { throw Missing(names: missing.map(\.rawValue)) }
            if models == nil { models = try await loader() }
            try Task.checkCancellation()   // Stop or Quit during starting wins here, before any store exists
            let core = try AppController(paths: paths, models: models!, config: config)
            self.core = core
            watcher = Task { for await e in core.engine.ended { sourceEnded(e) } }
            state = .running
            onStart(core.store)
            await serial { await self.reconcile() }   // restores the checkmarks; toggles made while starting are in `attached` already
        } catch is CancellationError {
        } catch { state = .failed("\(error)") }
    }

    /// Runs `op` after every earlier `serial` op: the only way the engine is touched (uncertainty 4).
    private func serial(_ op: @escaping @MainActor () async -> Void) async {
        let prev = chain
        let t = Task { await prev.value; await op() }
        chain = t
        await t.value
    }

    /// Makes the engine's sources equal `attached`: one step per loop turn, so `attached` is re-read after every await.
    private func reconcile() async {
        guard let core else { return }
        while true {
            if let t = attached.first(where: { !applied.contains($0.id) }) {
                applied.insert(t.id)
                do { await core.engine.attach(try makeSource(t)) } catch { fail(t, "\(error)") }
            } else if let id = applied.first(where: { id in !attached.contains { $0.id == id } }) {
                applied.remove(id)
                await core.engine.detach(id)
            } else { return }
        }
    }

    private func fail(_ t: Target, _ reason: String) {
        attached.removeAll { $0.id == t.id }
        failures[t.id] = "\(t.tag): \(reason)"
    }

    /// A source that ended unchecks; one that failed unchecks with its reason. The pipeline already committed the open segment and cleared the tail.
    private func sourceEnded(_ e: SourceEnd) {
        guard applied.remove(e.id) != nil, let t = attached.first(where: { $0.id == e.id }) else { return }   // a user detach removed the id first
        if let error = e.error { fail(t, "\(error)") } else { attached.removeAll { $0.id == t.id } }
    }

    /// Records the choice always; the engine follows when it exists, else at the next running.
    public func toggle(_ t: Target) async {
        failures[t.id] = nil
        if attached.contains(where: { $0.id == t.id }) { attached.removeAll { $0.id == t.id } } else { attached.append(t) }
        await serial { await self.reconcile() }
    }

    /// Ends every source (each commits its open segment) and keeps the checkmarks.
    public func stop() async {
        booting?.cancel()
        await booting?.value
        booting = nil
        watcher?.cancel()
        watcher = nil
        await serial {
            guard let core = self.core else { return }
            for id in self.applied { await core.engine.detach(id) }
            self.applied = []
            self.core = nil
        }
        state = .stopped
    }

    public func quit() async { await stop(); terminate() }
}
```
Pinned by tests: `start` from `.failed` clears the reason (state becomes `.starting`); `stop` from any state ends at `.stopped`; `toggle` while stopped or starting only edits `attached`; `makeSource` runs only while an engine exists.

## `Sources/TEUI/Row.swift`
```swift
import AppKit

/// A menu row that runs a closure; `on` shows the checkmark. `target` is the item itself (weak in AppKit), so no cycle.
@MainActor final class Row: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, on: Bool = false, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}
```

## `Sources/TEUI/MenuBar.swift` (S10 rewrites this file whole)
```swift
import AppKit

@MainActor public final class MenuBar {
    public let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let session: Session

    public init(session: Session) {
        self.session = session
        item.menu = NSMenu()
        session.observe { [weak self] in self?.render() }
        render()
    }
    deinit { NSStatusBar.system.removeStatusItem(item) }

    /// Rebuilt from the session on every change, so an open menu stays current.
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
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")   // no action: a disabled label
        menu.addItem(Row("Start transcription") { [session] in session.start() })
        menu.addItem(Row("Stop transcription") { [session] in Task { await session.stop() } })
        menu.addItem(.separator())
        menu.addItem(Row("Quit") { [session] in Task { await session.quit() } })
    }
}
```
Colours are the system palette. Failed and stopped share grey; the status row text tells them apart.

## `Sources/TranscribeEverything/main.swift` (edit: the `case nil:` arm only; `prefetch`, `verify`, usage arms unchanged)
```swift
case nil:
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let session = Session(config: ConfigStore(), onStart: { _ in })
    let bar = MenuBar(session: session)
    session.start()
    withExtendedLifetime((session, bar)) { app.run() }
```
S10, S11 and S14 each replace named lines of this arm; S15 shows its final text.

## `Tests/TECoreTests/AppRig.swift` (shared by S9 and S10)
```swift
actor Gate { /* wait(): returns at once if released, else suspends; release(): resumes all waiters, stays open */ }

@MainActor final class FakePermissions: Permissions {
    var have: Set<Permission>; let grantsOnRequest: Set<Permission>; private(set) var requested: [Permission] = []
    func granted(_ p: Permission) -> Bool { have.contains(p) }
    func request(_ p: Permission) async { requested.append(p); if grantsOnRequest.contains(p) { have.insert(p) } }
}

/// Shared by the rig's closures, which are built before the session exists.
@MainActor final class Counters {
    var loads = 0, loadFailures = 0, terminated = false
    var made: [SourceID: Int] = [:], gone: Set<SourceID> = [], provide: [SourceID: any AudioSource] = [:]
}

@MainActor final class Rig {
    let session: Session, bar: MenuBar, root: URL, c = Counters(), permissions: FakePermissions, config = ConfigStore()
    var history: [String] = []     // "<state>/<dot colour>" after each change that alters it
    init(_ test: XCTestCase, have: Set<Permission> = Set(Permission.allCases), grants: Set<Permission> = [], gate: Gate? = nil, loadFailures: Int = 0)
    func click(_ title: String)    // menu.performActionForItem(at: menu.indexOfItem(withTitle: title)); XCTAssertNotEqual(index, -1)
    var dot: String { dotColor(bar.item.button!.image!) }
    func files() -> [String]       // sorted names of *.jsonl in root/transcripts; [] if the directory does not exist
    func tail(_ id: SourceID) async -> Bool   // core's store snapshot().tails contains src == id; false while core is nil
}
```
`Rig.init`: `root = temporaryRoot(test)`; `permissions = FakePermissions(have:, grantsOnRequest: grants)`; `c.loadFailures = loadFailures`; `session = Session(paths: Paths(root: root), permissions:, config:, loader:, makeSource:, onStart: { _ in }, terminate:)` with
- `loader`: `c.loads += 1; await gate?.wait(); if c.loadFailures > 0 { c.loadFailures -= 1; throw Boom(description: "model download failed") }; return CoreModels(transcriber: try await Models.transcriber.value, embedder: try await Models.embedder.value, vad: try await Models.vad.value)`;
- `makeSource`: `c.made[t.id, default: 0] += 1; if c.gone.contains(t.id) { throw Boom(description: "not running") }; if let s = c.provide[t.id] { return s }; return try FileSource(url: Fixtures.conversationWav, id: t.id, tag: t.tag, clock: ContinuousClock())` (99 s real time: it cannot end inside a test unless a test provides another source);
- `terminate`: `c.terminated = true`.

Then `bar = MenuBar(session: session)`; then `session.observe { history.append(label(state) + "/" + dot) if different from the last }` (registered after the bar's, so the image is current). `label`: `stopped/starting/running/failed`.

`dotColor(_ image: NSImage) -> String` (test code, shares nothing with `MenuBar`): draw into a 16×16 RGBA `NSBitmapImageRep` as in the probe, read pixel (8, 8) in sRGB `(r, g, b)`: `"yellow"` if r > 0.9, 0.7 < g < 0.95, b < 0.2; `"green"` if r < 0.4, g > 0.7, 0.2 < b < 0.5; `"grey"` if |r−g| < 0.06, |g−b| < 0.06, 0.3 < g < 0.7; else `"other(r,g,b)"`. Ranges: probe colours (item 2) with margin for dark appearance.

## `Tests/TECoreTests/LifecycleTests.swift` (class `LifecycleTests`, category Lifecycle)
`@MainActor final class`; `setUp()`: `NSApplication.shared.setActivationPolicy(.accessory)`. Each test sets `executionTimeAllowance = 90` and ends with `await rig.session.stop()` in a teardown block. Real models via `Models`, real `FileSource`, real `NSMenuItem` actions; no permissions, no app, no cursor. `a = Target.app(bundleId: "test.a", tag: "Alpha")`, `b = …"test.b", tag: "Beta"`. Waits use S7's `eventually`.

1. **`testLaunchGoesYellowThenGreenAndTheIconFollowsAndDoubleStartIsANoOp`.** `session.start()`; eventually `.running`. `history == ["starting/yellow", "running/green"]`; menu item 0 title `"Running"`; `files().count == 1`; `permissions.requested == []`. Click Start again: `c.loads == 1`, `files().count == 1`, history unchanged. Click Stop: eventually `.stopped`; `dot == "grey"`; item 0 `"Stopped"`. Mutants: swap yellow/green ⇒ red; drop `state = .starting` ⇒ history lacks it ⇒ red; drop the state guard in `start` ⇒ a second boot writes a second file ⇒ red.
2. **`testOnlyMissingPermissionsAreRequestedAndAnyMissingKeepsTheEngineOff`.** `have: [.microphone]`. `start()`; eventually `state == .failed(expected)` with `expected = "Missing permission: Screen Recording. Grant it in System Settings, then relaunch."` (literal). `requested == [.screenRecording]`, menu item 0 title `== expected`, `dot == "grey"`, `files() == []`, `c.loads == 0`. Click Start: eventually `requested == [.screenRecording, .screenRecording]` (a granted permission is never requested), failed again. Rig `have: [], grants: [.microphone]`: `requested == [.microphone, .screenRecording]`, the failure names only Screen Recording (the re-read sees the grant). Rig `have: [], grants: []`: `"Missing permission: Microphone, Screen Recording. …"`. Mutants: request every permission ⇒ red; compute `missing` before the requests ⇒ second rig names both ⇒ red.
3. **`testAttachWhileStoppedOrStartingIsRecordedAndAppliedOnceWhenRunning`.** Rig 1: `await toggle(a)` while stopped ⇒ `attached == [a]`, `made[a.id] == nil`; `start()`; eventually `tail(a.id)`; `made[a.id] == 1`. Rig 2 with a `Gate`: `toggle(a)`, `start()`, eventually `.starting`; `toggle(b)` ⇒ `attached == [a, b]`, `made` empty; `toggle(b)` again ⇒ `attached == [a]`; `toggle(b)` again; `gate.release()`; eventually `tail(a.id)` and `tail(b.id)`; `made[a.id] == 1`, `made[b.id] == 1` (no source is attached twice, which would trip the engine's precondition). Rig 3 with a gate: `toggle(b)` then `toggle(b)`; release ⇒ `attached.isEmpty`, `made[b.id] == nil`, `tail(b.id)` is false. Mutants: `toggle` guards on `core` before recording ⇒ red; reconcile ignores `applied` ⇒ attaches twice ⇒ red; boot ignores `attached` ⇒ red.
4. **`testStopKeepsCheckmarksAndStartRestoresThemWithAFreshLookupAndANewFile`.** `toggle(a)`, `start()`, eventually `tail(a.id)`; click Stop; eventually `.stopped`: `core == nil`, `attached == [a]`, the first file holds ≥ 1 line (the open segment committed). Click Start; eventually `tail(a.id)`: `made[a.id] == 2` (looked up again), `files().count == 2`. Mutants: `stop` clears `attached` ⇒ red; no reconcile at boot ⇒ red; `stop` skips `detach` ⇒ file empty ⇒ red; `makeSource` result cached ⇒ `made == 1` ⇒ red.
5. **`testRestoringAnAppThatIsGoneUnchecksItWithTheReason`.** Attach `a` and `b`, start, eventually both tails, Stop. `c.gone = [b.id]`; Start; eventually `tail(a.id)`. `attached == [a]`, `failures[b.id] == "Beta: not running"`, `failures[a.id] == nil`. Mutants: `fail` leaves `b` in `attached` ⇒ red; reconcile swallows the factory error ⇒ red.
6. **`testStopOrQuitDuringStartingWinsWhenTheLoadFinishes`.** For `action in ["Stop transcription", "Quit"]`, each on a gate rig: `start()`, eventually `.starting`; click `action`; for Quit wait 0.3 s and assert `c.terminated == false` (quit waits for the load); `gate.release()`; eventually `.stopped` (Quit: also `c.terminated`). `history == ["starting/yellow", "stopped/grey"]` (never green), `core == nil`, `files() == []`, `c.loads == 1`. Mutants: delete `checkCancellation` ⇒ a file exists and history shows `running/green` ⇒ red; `quit` calls `terminate()` before `stop()` ⇒ `terminated` already true ⇒ red.
7. **`testAThrowingLoaderFailsWithTheReasonAndStartRetries`.** `loadFailures: 1`. `start()`; eventually `.failed("model download failed")`; menu item 0 the same, `dot == "grey"`, `files() == []`, `c.loads == 1`. Click Start; eventually `.running`; `c.loads == 2`. Mutant: `boot` catches and sets `.stopped` ⇒ red.
8. **`testQuitCommitsTheOpenSegmentThenTerminates`.** `toggle(a)`, `start()`, eventually `tail(a.id)`; capture `core` and `store`; `c0 = snapshot().lines.count`; click Quit; eventually `c.terminated`. `snapshot().tails.isEmpty`, `lines.count > c0`, the file's JSONL line count equals `lines.count`. Mutants: `quit` = `terminate()` only ⇒ tail remains ⇒ red; `stop` without `detach` ⇒ red.
9. **`testASourceThatEndsUnchecksAndCanBeAttachedAgain`.** `c.provide[a.id] = FileSource(url: Fixtures.turnWav(0), id: a.id, tag: "Alpha")` (un-paced, ends in seconds). Running rig; `toggle(a)`; eventually `attached.isEmpty`. `failures.isEmpty`, store `lines` non-empty with `tag == "Alpha"`, `tails.isEmpty`. Then `c.provide[a.id] = FileSource(url: Fixtures.turnWav(1), …)`; `toggle(a)`; eventually `attached.isEmpty` and `lines.count` grew. Mutants: no watcher ⇒ stays checked ⇒ red; `sourceEnded` does not remove the id from `applied` ⇒ the second attach never happens ⇒ red.
10. **`testAFailingSourceUnchecksWithItsReasonAndCommitsItsOpenSegment`.** `c.provide[a.id] = FailingSource(base: FileSource(url: Fixtures.conversationWav, id: a.id, tag: "Alpha", clock: ContinuousClock()), failAt: 49_152)` (3.07 s: turn 0 spans 0–3.03 s, so a segment is open). Running rig; `toggle(a)`; eventually `attached.isEmpty`. `failures[a.id] == "Alpha: boom"`, `tails.isEmpty`, `lines.count > 0`. `toggle(a)` ⇒ `failures[a.id] == nil` at once. Mutants: the watcher drops the error ⇒ red; `fail` leaves the target checked ⇒ red.

Each mutant: one edit, the single named test red, revert, green.

## Steps to attain the human-verifiable result
1. Order: `Permissions.swift` ⇒ `AppController.swift` ⇒ `Row.swift` ⇒ `MenuBar.swift` ⇒ `swift build` ⇒ `main.swift`, `Package.swift`, `Boom` ⇒ `AppRig.swift`, `LifecycleTests.swift` ⇒ `./test.sh Lifecycle` under pacemaker ⇒ mutants ⇒ full `./test.sh` (S1–S8 unchanged) ⇒ fresh adversarial review.
2. `./build.sh`; `open ~/Applications/TranscribeEverything.app`: the menu-bar dot is yellow, then green; `ls -t ~/.transcribe-everything/transcripts | head -1` is a new file; the menu shows Running; Stop turns it grey, Start yellow then green, Quit removes the dot and `pgrep -x TranscribeEverything` is empty.
