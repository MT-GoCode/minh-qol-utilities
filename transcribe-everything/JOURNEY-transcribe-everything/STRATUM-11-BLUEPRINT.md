# Stratum 11 Blueprint — Overlay: see-through captions that expire

Written together with S12 and S13 (all three own `Overlay.swift`; S12 and S13 add to the shapes fixed here and replace the few lines they name). Builds on S1–S5 (`render`, `Rendered.nextChange`, `Snapshot`, `store.changes`), S6/S7 `Verify`/`Step`/`AppHarness`, S7's `eventually`, and S9's `Session` (main wires the overlay; this file never imports `Session`).

# Uncertainties squashed

Probes (`/tmp/te-ovl-probe/{p,q,r}.swift`, headless, no app, no mouse). The screen was locked (`CGSSessionScreenIsLocked == 1`), so anything needing a key window was NOT observable (item 8).

1. **TextKit 1 is available and sized automatically.** `NSTextView(usingTextLayoutManager: false)` (`NSTextView.h:98`) has a non-nil `layoutManager`. With `isVerticallyResizable = true`, `autoresizingMask = [.width]`, `minSize = .zero`, `maxSize = 1e7`, `textContainer.widthTracksTextView = true` inside a scroll view: 12 lines at 22 pt semibold ⇒ `usedRect.height 312`, `tv.frame.height 312` after `ensureLayout` (26 pt per line). `tv.scroll(NSPoint(x:0, y: frame.height − clip.height))` puts the clip at `{0,212,760,100}`; `tv.scroll(.zero)` ⇒ `{0,0,…}`.
2. **Equal text must not be rewritten.** `textStorage.isEqual(to: newAttributedString)` is true for identical string and attributes (font size included). `setAttributedString` collapses the selection to the end and posts `NSTextView.didChangeSelectionNotification` (S13 relies on the skip).
3. **`render`'s edge is inclusive** (`Render.swift`): a line is in while `t >= now − window`, `nextChange = t + window`. Waking exactly at `nextChange` redraws the same result with `nextChange == now`: a hot loop. The wake time is `nextChange.timeIntervalSinceReferenceDate.nextUp`.
4. **Draws are serial.** `store.snapshot()` and `config.current` are actor awaits; two concurrent draws could apply an older snapshot last. One consumer loop over an `AsyncStream<Void>` (`bufferingNewest(1)`, the idiom of `TranscriptStore.changes`) runs every draw; store changes, `refresh()`, config changes and the expiry timer only `yield` to it.
5. **`refresh()` returns the draw it caused**: a `Task<Void, Never>` that completes after a draw that started after the call (waiters are captured before each draw). Callers ignore it; tests `await` it, so only the two tests that prove a path with no handle (store subscription, expiry timer) poll with `eventually`.
6. **Click-through geometry is AppKit's own**: `NSView.convert(_:to: nil)` handles flipped views, `NSWindow.convertPoint(fromScreen:)` maps the mouse. The bar's interactive rectangles are its visible subviews, so S12 adds controls with no change to the poll.
7. **Window-scoped capture under the app identity.** `verify` runs under the bundle that holds Screen Recording (S6). The `overlay` op captures its own panel in-process with `SCScreenshotManager` and writes a PNG; the test process reads pixels with CoreGraphics and OCRs with Vision (no permission needed). APIs exist (SDK headers): `NSView.needsPanelToBecomeKey`, `NSPanel.becomesKeyOnlyIfNeeded`, `SCScreenshotManager.captureImageWithFilter:configuration:` (macOS 14, `SCScreenshotManager.h:153`), `SCStreamConfiguration.ignoreShadowsSingleWindow` (macOS 14, `SCStream.h:340`), `SCWindow.windowID`, `SCContentFilter(desktopIndependentWindow:)`.
8. **NOT observable on a locked screen, settled at build** (a red is a finding: stop and report, never loosen or branch): (a) whether a `SCContentFilter(desktopIndependentWindow:)` PNG keeps alpha 0 over a clear panel; (b) whether `verify`'s run loop draws the panel in time for capture; (c) whether `isKeyWindow` becomes true in the `swift test` process after a synthesized text click (S12/S13).
9. **Draw cost is bounded.** Text is written only when it differs, `place()` sets frames only when the body height changed, and the click-through timer skips a hidden panel and has tolerance. `render` already bounds its input (`Render.swift:19`). Deferred (OTHER.md): provisional rows render like committed ones.

# Blueprint

New: `Sources/TEUI/{Overlay,VerifyOverlay}.swift`, `Tests/TECoreTests/{OverlaySupport,OverlayTests}.swift`. Edited: `Sources/TEUI/Verify.swift`, `Sources/TranscribeEverything/main.swift`. `Package.swift` already has `TEUI` in the test target (S9).

## `Sources/TECore/Config.swift` (edit)
`Overlay` subscribes to `changes()` here; S14 replaces this file whole and keeps the same method. Add to `ConfigStore` (and change `set` as shown; it stays non-throwing until S14, and `try await` on it compiles with a warning, so call sites need no edit at S14):
```swift
private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
public func set(_ config: Config) {
    guard config != current else { return }
    current = config
    for c in subscribers.values { c.yield() }
}
/// Yields after every change of `current`. One stream per caller.
public func changes() -> AsyncStream<Void> {
    let id = UUID()
    let (stream, c) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    c.onTermination = { _ in Task { await self.drop(id) } }
    subscribers[id] = c
    return stream
}
private func drop(_ id: UUID) { subscribers[id] = nil }
```
Add `import Foundation`.

## `Sources/TEUI/Overlay.swift`
```swift
import AppKit
import TECore

/// Wall clock and a sleep on it; the one injection point for time.
public struct OverlayTime: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Date) async throws -> Void
    public static let system = OverlayTime(now: { Date() }, sleep: { try await Task.sleep(for: .seconds(max(0, $0.timeIntervalSinceNow))) })
}

public final class OverlayPanel: NSPanel { override var canBecomeKey: Bool { true } }

/// Clicking the text takes the keyboard (copy needs it); bar controls do not (becomesKeyOnlyIfNeeded).
public final class CaptionText: NSTextView { override var needsPanelToBecomeKey: Bool { true } }
```
`@MainActor public final class Overlay: NSObject`. Constants and origins:
- `width = 760.0` — the probed panel (`spike Probe ui()`), confirmed by Minh's real mouse.
- `barHeight = 28.0` — the probe's 24 pt grip + 4.
- `maxHeightFraction = 0.4` — DECISIONS ("height up to 40% of the screen").
- click-through poll interval `1.0/60`, tolerance `1.0/240` — the interval is the probe's, confirmed by Minh's real mouse; the tolerance is a quarter period, slack for the system to coalesce wakeups that keeps a flip within one display refresh.
- shadow: black, `shadowBlurRadius = 3`; text white, `.systemFont(ofSize: fontSize, weight: .semibold)` — the probe.
- follow tolerance `1` pt — layout rounding slack (the probe measured exact equality).

State: `public let panel: OverlayPanel`, `public let text: CaptionText`; private `scroll: NSScrollView`, `bar: NSView`, `config: ConfigStore`, `attached: @MainActor () -> Set<SourceID>`, `time: OverlayTime`, `store: TranscriptStore?`, `feed: Task<Void, Never>?`, `expiry: Task<Void, Error>?`, `placed: CGFloat?`, `follows = true`, `kicks: AsyncStream<Void>.Continuation`, `waiters: [CheckedContinuation<Void, Never>]`; module-internal `expanded = false` (S12 toggles it).

```swift
public init(config: ConfigStore, attached: @escaping @MainActor () -> Set<SourceID>, time: OverlayTime = .system) {
    // panel: default frame = width × barHeight, horizontally centred, top at 45% of screens[0].visibleFrame height
    //        (leaves the 40% maximum growth room below the top; a decision, not measured)
    panel = OverlayPanel(contentRect: ..., styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false   // a shadow would draw around the text on a clear window
    panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false      // NSPanel hides with the app by default; an accessory app deactivates whenever a menu closes
    panel.becomesKeyOnlyIfNeeded = true
    // text: exactly the settings of uncertainty 1 + isEditable = false, isSelectable = true, drawsBackground = false, frame width = Self.width
    // scroll: documentView = text, drawsBackground = false, hasVerticalScroller = false (the wheel still scrolls)
    // contentView.subviews = [bar, scroll]
    // (kicks, stream) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    Task { [weak self] in                   // the draw loop; a dropped Overlay ends it
        for await _ in stream {
            guard let self else { return }
            let ws = waiters; waiters = []
            await draw()
            ws.forEach { $0.resume() }
        }
    }
    Task { [weak self] in                   // a changed config (font size, windows) redraws, and ends any selection like any user change
        for await _ in await config.changes() { guard let self else { return }; userChange() }
    }
    let poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
        MainActor.assumeIsolated {
            guard let self else { return t.invalidate() }
            if panel.isVisible { pollMouse(at: NSEvent.mouseLocation, pressed: NSEvent.pressedMouseButtons) }
        }
    }
    poll.tolerance = 1.0 / 240
    panel.orderFrontRegardless()
}

public func bind(_ store: TranscriptStore) {     // one per engine start (Session's onStart calls it)
    feed?.cancel(); self.store = store
    feed = Task { [kicks] in for await _ in store.changes { kicks.yield() } }
    refresh()
}

/// Anything but the store: the attach set, failures, hide/expand.
@discardableResult public func refresh() -> Task<Void, Never> {
    Task { await withCheckedContinuation { waiters.append($0); kicks.yield() } }
}

/// A change the user asked for ends any selection (S13's hold would otherwise keep it from drawing), then redraws.
func userChange() { text.setSelectedRange(NSRange(location: 0, length: 0)); refresh() }

/// Click-through: only bar controls and the text itself take the mouse. Frozen while a button is down so a drag never flips it.
public func pollMouse(at p: NSPoint, pressed: Int) {
    guard pressed == 0 else { return }
    let w = panel.convertPoint(fromScreen: p)
    panel.ignoresMouseEvents = !interactive.contains { $0.contains(w) }
}
private var interactive: [NSRect] {          // window coordinates
    let used = text.layoutManager!.usedRect(for: text.textContainer!)
    return bar.subviews.filter { !$0.isHidden }.map { $0.convert($0.bounds, to: nil) }
        + [text.convert(used, to: nil).intersection(scroll.convert(scroll.bounds, to: nil))]
}

private func draw() async {
    guard let store else { return }
    let snapshot = await store.snapshot(), config = await config.current
    let r = render(snapshot: snapshot, attached: attached(), now: time.now(), expanded: expanded, config: config)
    if scroll.frame.height > 0 { follows = scroll.contentView.bounds.maxY >= text.frame.height - 1 }   // true when the content fits; a zero-height view has no position
    writeText(r, config)
    place()
    if follows { text.scroll(NSPoint(x: 0, y: max(0, text.frame.height - scroll.contentView.bounds.height))) }
    expiry?.cancel()
    expiry = r.nextChange.map { next in   // wake at the first instant the result differs (uncertainty 8)
        Task { [kicks, time] in
            try await time.sleep(Date(timeIntervalSinceReferenceDate: next.timeIntervalSinceReferenceDate.nextUp))
            kicks.yield()
        }
    }
}

private func writeText(_ r: Rendered, _ config: Config) {
    let shadow = NSShadow(); shadow.shadowColor = .black; shadow.shadowBlurRadius = 3
    let s = NSAttributedString(string: r.rows.map(\.text).joined(separator: "\n"), attributes: [
        .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: CGFloat(config.fontSize), weight: .semibold), .shadow: shadow])
    if !text.textStorage!.isEqual(to: s) { text.textStorage!.setAttributedString(s) }
}

/// Top stays fixed; the panel grows downward. Sets frames only when the body height changed.
private func place() {
    text.layoutManager!.ensureLayout(for: text.textContainer!)
    let used = text.layoutManager!.usedRect(for: text.textContainer!).height
    let body = min(used, Self.maxHeightFraction * (panel.screen ?? NSScreen.screens[0]).visibleFrame.height)
    guard body != placed else { return }
    placed = body
    let f = panel.frame, h = Self.barHeight + body
    panel.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: Self.width, height: h), display: true)
    bar.frame = NSRect(x: 0, y: body, width: Self.width, height: Self.barHeight)
    scroll.frame = NSRect(x: 0, y: 0, width: Self.width, height: body)
}
```
`follows` is read before the text changes. Order inside `draw`: render, follow, write, place, scroll, expiry. `store.changes` yields after every commit and tail change.

## `Sources/TEUI/VerifyOverlay.swift`
```swift
struct OverlaySpec: Decodable { let lines: [String]; let png: String }    // {"op":"overlay","lines":[…],"png":"<path>"}
struct OverlayTextMismatch: Error { let seen: String }

extension AppController {
    @MainActor func overlay(_ s: OverlaySpec) async throws -> [String: Any]
}
```
`overlay` (the capture test's vehicle):
```
NSApplication.shared.setActivationPolicy(.accessory)
let id = SourceID(rawValue: "verify"); let o = Overlay(config: ConfigStore(), attached: { [] }); o.bind(store)
for t in s.lines { try await store.commit([Line(t: Date(), src: id, tag: "v", spk: 1, text: t, start: 0, end: 0)], of: id) }
await o.refresh().value
guard o.text.string == s.lines.joined(separator: "\n") else { throw OverlayTextMismatch(seen: o.text.string) }   // one source, none attached: untagged
CATransaction.flush()
repeat { win = SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).windows.first { $0.windowID == CGWindowID(o.panel.windowNumber) }; if nil, sleep 1/60 s } until win != nil
let scale = o.panel.backingScaleFactor
cfg = SCStreamConfiguration(); cfg.width = Int(frame.width*scale); cfg.height = Int(frame.height*scale); cfg.showsCursor = false; cfg.ignoreShadowsSingleWindow = true
image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win!), configuration: cfg)
write PNG with CGImageDestination (UTType.png) to s.png
return ["op": "overlay", "png": s.png, "pointsWidth": frame.width, "pointsHeight": frame.height]
```
`Verify.swift` (edit, S7's pattern): `case overlay(OverlaySpec)`; decode arm `case "overlay": self = .overlay(try OverlaySpec(from: decoder))`; run arm `case .overlay(let s): return try await app.overlay(s)`.

## `Sources/TranscribeEverything/main.swift` (edit the `case nil:` arm; final text in S15)
Replace the `Session(...)` line and add the overlay lines so the arm reads, at this stratum:
```swift
var session: Session!                 // the overlay reads the session through closures and the session starts the overlay: neither can be built first
let overlay = Overlay(config: config, attached: { Set(session.attached.map(\.id)) })
session = Session(config: config, onStart: { overlay.bind($0) })
session.observe { overlay.refresh() }
```
with `let config = ConfigStore()` above them (S14 replaces it by the file-backed store), and `overlay` added to the `withExtendedLifetime` tuple. `MenuBar`'s `settings:` stays `[]` until S12.

## `Tests/TECoreTests/OverlaySupport.swift`
```swift
final class FakeTime: @unchecked Sendable {            // lock-protected
    let base: Date; private(set) var current: Date; private(set) var deadlines: [Date] = []
    private var waiters: [(Date, CheckedContinuation<Void, Error>)] = []
    var time: OverlayTime { OverlayTime(now: { self.current }, sleep: { try await self.sleep(until: $0) }) }
    func sleep(until d: Date) async throws { record d; if d <= current { return }; try await withCheckedThrowingContinuation { waiters.append((d, $0)) } }
    func advance(by s: Double) { current += s; resume every waiter whose deadline <= current }
}
@MainActor final class OverlayRig {
    let time: FakeTime; let config: ConfigStore; var attached: Set<SourceID> = []; let store: TranscriptStore; let overlay: Overlay
    init(_ test: XCTestCase, config: ConfigStore = ConfigStore()) throws    // NSApplication.shared; FakeTime(base: 2027-01-15 08:00:00Z); TranscriptStore(paths: Paths(root: temporaryRoot(test)), start: base);
                                       // overlay = Overlay(config:, attached: { [unowned self] in attached }, time: time.time); overlay.bind(store);
                                       // test.addTeardownBlock { overlay.panel.close() }
    func say(_ src: String, _ text: String, tag: String = "Zoom", spk: Int = 1) async throws   // commit one Line(t: time.current, …)
}
```
A cancelled waiter in `FakeTime` stays pending and later causes one harmless extra kick (an equal-text draw is a no-op).

## `Tests/TECoreTests/OverlayTests.swift` (`@MainActor final class OverlayTests`, category Overlay)
Expected strings are written by hand from the lines; no test calls `render`. Waits use S7's `eventually`.

1. **`testCaptionsAppearAsRenderedAndLeaveDuringSilence`.** `attached = {A}`. `say("A","Hello there.")` (t = B). `eventually("subscription") { text.string == "Hello there." }` (proves `bind` ⇒ `changes` ⇒ draw). `time.advance(3)`; `say("A","Second line.")`; `await overlay.refresh().value`; expect `"Hello there.\nSecond line."`. `attached = {A,B}`; `refresh().value`; expect `"[Zoom] Hello there.\n[Zoom] Second line."`. `time.advance(17)` (now = B+20 exactly); `refresh().value`; both still shown (edge inclusive). `time.advance(1)` (B+21); no refresh: `eventually("expiry") { text.string == "[Zoom] Second line." }`. `time.advance(3)` (B+24): `eventually { text.string == "" }`; `panel.frame.height == 28`. Mutants: no `expiry` task ⇒ red; `draw` passes `[]` for `attached` ⇒ tagged expectation red.
2. **`testWakeIsAfterTheEdgeNeverAtIt`.** `say("A","One.")` at B, `refresh().value`. `time.deadlines` is non-empty and `allSatisfy { $0 > B + 20 }`. Mutant: `next` without `.nextUp` ⇒ one deadline equals B+20 ⇒ red.
3. **`testProvisionalTailShowsLastAndACommitReplacesItAtomically`.** `attached={A}`; `say("A","First.")`; `setTail(Provisional(src: A, tag: "Zoom", spk: 1, text: "and then"), epoch: await store.epoch(of: A))`; `refresh().value`; expect `"First.\nand then"`. `say("A","And then we left.")`; `refresh().value`; expect `"First.\nAnd then we left."`. Mutant: draw ignores tails ⇒ red.
4. **`testOverflowKeepsTheNewestLineVisibleAtFontFortyEight`.** `var c = Config(); c.fontSize = 48; try await config.set(c)`; three sources A, B, C attached; 12 lines "Line k from <src>." (k = 1…12) round robin, all at B. `refresh().value`. Vacuity guard: `text.frame.height > scroll.frame.height`. `panel.frame.height <= 28 + 0.4 × screens[0].visibleFrame.height + 0.5`; the last line's glyph rect (`layoutManager.lineFragmentRect(forGlyphAt: numberOfGlyphs − 1, effectiveRange: nil)`) is inside `text.visibleRect`. Mutant: no follow-scroll ⇒ red.
5. **`testScrolledUpHoldsTheViewAndFollowingResumesAtTheBottom`.** From test 4's rig (a helper builds it). `text.scroll(.zero)`; `say` a 13th line; `refresh().value`; `scroll.contentView.bounds.origin.y == 0` and the string ends with the new line. Scroll to the bottom (`y = text.frame.height − clip.height`); `say` a 14th line; `refresh().value`; the last line's rect is inside `text.visibleRect`. Mutants: always scroll to end ⇒ first assertion red; `follows` never recomputed ⇒ second red.
6. **`testClickThroughFollowsTheMouseAndFreezesWhileAButtonIsDown`.** `attached = {A}`, `say("A","Hello there.")`, `refresh().value`. `over` = screen point of the centre of the first line fragment (`lineFragmentUsedRect(forGlyphAt: 0)` ⇒ `text.convert(_, to: nil)` ⇒ `panel.convertToScreen`); `away` = same y, x = `panel.frame.maxX − 2` (assert the line's used width < 756, so `away` is blank). `pollMouse(away, 0)` ⇒ `ignoresMouseEvents == true`; `(over, 0)` ⇒ false; `(away, 1)` ⇒ still false; `(away, 0)` ⇒ true; `(over, 1)` ⇒ still true. Mutants: inverted test ⇒ red; ignoring `pressed` ⇒ the `(away,1)` line red.
7. **`testAConfigChangeRedrawsWithoutAnyRefreshCall`.** `say("A","Hello there.")` with `attached = {A}`, `refresh().value`; the font of the string's first character is 22. `try await config.set(c with fontSize 31)`; `eventually("font") { first-character font pointSize == 31 }` (read from `text.textStorage!.attribute(.font, at: 0, …)`). Mutant: delete the config subscription ⇒ red.
8. **`testWindowCaptureIsTransparentAndOCRReadsTheLatestLine`** (under `AppHarness`; first `try AppHarness.requireUnlocked()`; `executionTimeAllowance = 240`). Steps: `[["op":"overlay","lines":["Good morning everyone.","The quick brown fox jumps over the lazy dog."],"png": resultsDir()/overlay.png]]`. Read the PNG with `CGImageSource`; `scale = image.width / report.pointsWidth`. Blank points (pixels, top-left origin): `(w − 4pt, 14pt)` in the bar, and `(w − 4pt, 28pt + 10pt)` right of the first line. Draw the image into an RGBA8 premultiplied context of its size and read byte `[(y·w + x)·4 + 3]`: both alphas `== 0`. Text present: max alpha over the text rows `== 255`. OCR: composite onto opaque black, `VNRecognizeTextRequest` (`.accurate`, `usesLanguageCorrection = false`); `normalize(all recognized strings joined by " ")` contains `normalize("The quick brown fox jumps over the lazy dog.")`. Mutants: opaque `backgroundColor` ⇒ alpha 255 ⇒ red; text alpha 0 ⇒ OCR red.

Each mutant: one edit, the named test red, revert, green. Tests 1–7 run on any host with a display; 8 needs the unlocked Mac.

## Steps to attain the human-verifiable result
1. `Overlay.swift`, `OverlaySupport.swift`, tests 1–7; `./test.sh Overlay` green (panels flash briefly on screen; they never touch the cursor).
2. `VerifyOverlay.swift` + `Verify.swift` + `main.swift` edits; test 8 on mac-work-2 unlocked; open `test-results/<ts>/overlay.png` (text on a transparent background).
3. Mutants.
4. **Human gate.** `./build.sh`, open the app, play `conversation.wav` in QuickTime, attach QuickTime from Attach to Apps. Minh reads the captions over another app and over a full-screen app, and clicks on empty panel area: the click reaches the app beneath, while a click on a caption line does not.
5. Fresh adversarial review.

# Build findings (supersede the sections above)
- `usedRect(for:)` spans the container's full width, so click-through uses each visible line's own used rect: a click beside a short line reaches the app beneath.
- An empty text view still lays out one line, so an empty text means a zero body.
- Test 5 allows 1 pt on the scroll origin: AppKit rounds it on a fractional panel height.
- Test 8 runs with the screen locked too: a window capture of the panel works there as long as the display is awake (measured).
- The `overlay` op fails with a named error if the panel is not listed within 15 s.
