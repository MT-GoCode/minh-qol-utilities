# Stratum 12 Blueprint — Overlay bar: grip, expand, hide

Written together with S11 and S13. Extends `Overlay.swift` and `OverlaySupport.swift` from the S11 blueprint (shapes: `OverlayTime`, `OverlayRig`, `FakeTime`, `refresh()`, `userChange()`, `place()`, `draw()`, `interactive`, `bind`) and `main.swift`.

# Uncertainties squashed

1. **Bar controls need first mouse**: a synthesized click through `panel.sendEvent` on a non-key panel fired a button whose `acceptsFirstMouse` was true and not one whose was false (probe `/tmp/te-ovl-probe/p.swift`). Every bar control inherits one `BarButton` that returns true.
2. **The grip is a button subclass.** `performDrag(with:)` from a first-mouse view moves the panel, and polling with frozen buttons keeps click-through stable: Minh's real mouse (DECISIONS). A stock control has no hook to call `performDrag` on mouse-down, so `Grip` (one override, extending `BarButton`) is the smallest class that can. The drag needs the real mouse: human gate.
3. **Autosave.** `setFrameAutosaveName` returns true and restores the saved origin immediately; names are not exclusive among live windows; state lives in `UserDefaults` under `NSWindow Frame <name>` (tests use a UUID name and remove the key). `eye` and `eye.slash` SF Symbols exist (probe).
4. **Clamp only at restore.** A clamp at every `place()` would fight a drag across two displays (the larger screen wins and pulls the window back). Growth past the bottom of the screen is the user's own placement.
5. **Hide is a zero body, not a hidden view.** `body = 0` makes the panel bar-only and the text rectangle empty, so `interactive` excludes it with no new guard. While hidden, `draw` writes nothing and arms no expiry; Show redraws once.
6. **One owner, derived views.** `captionsHidden` is the only copy; the eye image, the menu title and the panel height derive from it in one `didSet`. `Overlay` vends the menu item (`hideShowItem`); main passes it to `MenuBar(settings:)`.
7. **Failure text comes from the session.** `Overlay` receives `failures: @MainActor () -> [String]` (main passes `session.failures.values.sorted()`), re-read on every draw; `session.observe { overlay.refresh() }` (main) redraws when one is set or cleared. The note updates while the captions are hidden: a failure matters most then. Delete errors never reach the bar.
8. **Key behaviour of a synthesized click is not observable on a locked screen** (S11 item 8c). Test 8 states it with `requireUnlocked()` and stops-and-reports on red.

# Blueprint

Edited: `Sources/TEUI/{Overlay,VerifyOverlay}.swift`, `Sources/TranscribeEverything/main.swift`, `Tests/TECoreTests/OverlaySupport.swift`. New: `Tests/TECoreTests/BarTests.swift`.

## `Overlay.swift`

Classes (file-private, next to `CaptionText`):
```swift
class BarButton: NSButton { override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true } }
final class Grip: BarButton { override func mouseDown(with e: NSEvent) { window!.performDrag(with: e) } }
```
`init` becomes `init(config:, attached:, failures: @escaping @MainActor () -> [String] = { [] }, autosaveName: String = "TranscribeEverythingOverlay", time: OverlayTime = .system)`; S11's call sites stay valid.

Constants: control frame 24 × 24 at `y = 2`, pitch 28, first `x = 4` (the probe's 28 × 24 grip + 4); glyph size 18 (probe grip font); note font `.systemFont(ofSize: 13, weight: .semibold)`, `noteX = 4 + 3 × 28 = 88`, `y = 5`, height 18. All white with the S11 shadow.

Bar views (created in `init`, added to `bar`, each with `identifier = NSUserInterfaceItemIdentifier(...)`, `isBordered = false`):
- `grip = Grip(title: "", target: nil, action: nil)`, `attributedTitle = styled("\u{283F}", 18)`, id `"grip"`.
- `expand = BarButton(title: "", target: self, action: #selector(toggleExpanded))`, `attributedTitle = styled("\u{2303}", 18)`, id `"expand"`.
- `eye = BarButton(title: "", target: self, action: #selector(toggleCaptions))`, `imagePosition = .imageOnly`, `symbolConfiguration = .init(pointSize: 18, weight: .semibold)`, `contentTintColor = .white`, `image = Self.eyeImage(hidden: false)`, id `"eye"`.
- `note = NSTextField(labelWithString: "")`, font above, `textColor = .white`, `lineBreakMode = .byTruncatingTail`, `isHidden = true`, id `"failure"`.
- `styled(_ s: String, _ size: CGFloat) -> NSAttributedString`: white, `.systemFont(ofSize: size, weight: .semibold)`, the S11 shadow. The three controls are laid out once, at `x = 4, 32, 60`.

State and menu:
```swift
public private(set) var captionsHidden = false {
    didSet { eye.image = Self.eyeImage(hidden: captionsHidden); hideShowItem.title = captionsHidden ? "Show" : "Hide"; userChange() }
}
public let hideShowItem: NSMenuItem   // built after super.init(): title "Hide", action #selector(toggleCaptions), target self, no key equivalent
@objc public func toggleCaptions() { captionsHidden.toggle() }
@objc private func toggleExpanded() { expanded.toggle(); userChange() }
private static func eyeImage(hidden: Bool) -> NSImage { NSImage(systemSymbolName: hidden ? "eye.slash" : "eye", accessibilityDescription: nil)! }

private func setNote() {
    let s = failures().joined(separator: "  ")
    guard s != note.stringValue else { return }
    note.stringValue = s
    note.isHidden = s.isEmpty
    note.frame = NSRect(x: Self.noteX, y: 5, width: min(note.fittingSize.width, Self.width - Self.noteX), height: 18)
}
```
`interactive` (S11) lists visible `bar.subviews`, so the grip, buttons and a non-empty note take the mouse and the rest of the bar passes through.

Two replacements in S11's text:
- in `draw()`, the first line `guard let store else { return }` becomes
```swift
setNote()
guard let store, !captionsHidden else { expiry?.cancel(); place(); return }
```
- in `place()`, `let body = min(used, …)` becomes `let body = captionsHidden ? 0 : min(used, Self.maxHeightFraction * (panel.screen ?? NSScreen.screens[0]).visibleFrame.height)`.

Frame persistence, at the end of `init` before `orderFrontRegardless()`:
```swift
precondition(panel.setFrameAutosaveName(autosaveName))     // restores a saved frame, if any
panel.setFrame(Self.clamp(panel.frame, into: NSScreen.screens.map(\.visibleFrame)), display: false)

/// Moves `f` fully inside the screen it overlaps most (ties and no overlap: the first screen).
public static func clamp(_ f: NSRect, into screens: [NSRect]) -> NSRect {
    func area(_ r: NSRect) -> CGFloat { r.width * r.height }
    let s = screens.max { area($0.intersection(f)) < area($1.intersection(f)) }!
    var g = f
    g.origin.x = max(s.minX, min(g.minX, s.maxX - g.width))
    g.origin.y = max(s.minY, min(g.minY, s.maxY - g.height))
    return g
}
```

## `VerifyOverlay.swift` and `main.swift` (edits)
- `overlay` op: `Overlay(config: ConfigStore(), attached: { [] }, autosaveName: "TranscribeEverythingVerify")`, so a verify run never restores or overwrites Minh's frame.
- `main.swift`: the `Overlay(...)` call gains `failures: { session.failures.values.sorted() }`; `MenuBar(..., settings: [overlay.hideShowItem])`.

## `OverlaySupport.swift` edits
`OverlayRig`: add `var failures: [String] = []` passed as `failures: { [unowned self] in failures }`; `let autosaveName = UUID().uuidString` passed as `autosaveName:`; teardown also `UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(autosaveName)")`. Add:
```swift
@MainActor func click(_ panel: NSPanel, atWindowPoint p: NSPoint)   // queue mouseUp (NSApp.postEvent atStart:false), then panel.sendEvent(mouseDown)
func find<T: NSView>(_ id: String, in v: NSView) -> T               // depth-first on NSUserInterfaceItemIdentifier
```
Events: `NSEvent.mouseEvent(with:location:modifierFlags: []:timestamp: ProcessInfo.processInfo.systemUptime:windowNumber: panel.windowNumber:context: nil:eventNumber: 0:clickCount: 1:pressure: 1)`. The mouse-up is queued first because a control's tracking loop blocks until it arrives.

## `Tests/TECoreTests/BarTests.swift` (`@MainActor final class BarTests`, category Bar)
Views by `find(id, in: panel.contentView!)`; waits use `eventually`.

1. **`testFrameRestoresFromTheAutosaveName`.** Rig; `v = NSScreen.screens[0].visibleFrame`; `panel.setFrameOrigin(NSPoint(x: v.minX + 123, y: v.minY + 321))`. A second `Overlay(config:, attached: { [] }, autosaveName: rig.autosaveName)` (closed in teardown) has `panel.frame.minX == v.minX + 123` and `maxY == v.minY + 321 + 28`. Mutant: no `setFrameAutosaveName` ⇒ red.
2. **`testClampMovesAFrameOntoTheScreenHoldingMostOfIt`.** Screens `A = (0,0,1440,900)`, `B = (1440,0,1920,1080)`. `(5000,5000,760,100)` with `[A]` ⇒ `(680,800)`; `(−100,−50,760,100)` ⇒ `(0,0)`; `(1500,200,760,100)` with `[A,B]` unchanged; `(1400,100,760,100)` with `[A,B]` ⇒ x `1440` (B overlaps more); `(9000,9000,760,100)` with `[A,B]` ⇒ lands in A. Mutants: always screen 0 ⇒ the 1400 row red; no clamp ⇒ red.
3. **`testRestoredOffScreenFrameEndsOnARealScreen`.** `panel.setFrameOrigin(90000, 90000)`; precondition `panel.frame.minX == 90000` (else vacuous). A second overlay with the same name: some `NSScreen.screens[i].visibleFrame.contains(panel.frame)`. Mutant: remove the `setFrame(clamp…)` ⇒ red.
4. **`testGlyphsAndExpandShowsLinesOlderThanTwentySeconds`.** `grip.attributedTitle.string == "\u{283F}"`; `expand.attributedTitle.string == "\u{2303}"`. `attached = {A}`; `say("A","Old line.")` at B; `time.advance(30)`; `refresh().value` ⇒ `text.string == ""`. `expand.performClick(nil)`; `refresh().value` ⇒ `"Old line."`. `performClick` again; `refresh().value` ⇒ `""`. Mutant: `expanded` not passed to `render` ⇒ red.
5. **`testEyeHidesCaptionsKeepsTheBarAndShareStateWithTheMenuItem`.** `say("A","Hello there.")`; `refresh().value`; `captionsHidden == false`; eye tiff equals a fresh `"eye"` symbol's; `hideShowItem.title == "Hide"`. `eye.performClick(nil)`; `refresh().value`: `captionsHidden`; `panel.frame.height == 28`; grip, expand, eye `isHidden == false` and `window != nil`; eye tiff equals `"eye.slash"`; title `"Show"`; `pollMouse` at the eye's screen centre ⇒ `ignoresMouseEvents == false`. While hidden, `say("A","Later line.")`, `refresh().value`: `text.string` is still `"Hello there."` (no draw while hidden). Then `NSApp.sendAction(hideShowItem.action!, to: hideShowItem.target, from: hideShowItem)` ⇒ `captionsHidden == false`, `text.string == "Hello there.\nLater line."`, plain eye, `"Hide"`, `panel.frame.height > 28`. Then the menu item hides and the eye shows again. Mutants: the eye keeps its own flag ⇒ the menu-then-eye leg red; hide leaves the body height ⇒ the `28` assertion red; draw while hidden ⇒ the `"Hello there."` check red.
6. **`testFailureReasonShowsInTheBarEvenWhileHiddenUntilCleared`.** `failures = ["Zoom: no audio buffers for more than 1 second"]`; `refresh().value`; `note.stringValue` equals it; `!note.isHidden`; `pollMouse` at the note's screen centre ⇒ not ignoring. Hide the captions, `failures = ["Zoom: no audio buffers for more than 1 second", "Mic: gone"]`, `refresh().value`: `note.stringValue` carries both, joined by two spaces. `failures = []`; `refresh().value` ⇒ `note.stringValue == ""`, `note.isHidden`, `pollMouse` at the old centre ⇒ ignoring. Mutants: note not cleared ⇒ red; `setNote` after the hidden guard ⇒ the hidden leg red.
7. **`testAMinuteOfLinesAtFontFortyEightIsAllReachable`.** `fontSize` 48 via `config.set`; `attached = {A}`; 14 times `say("A","Line k.")` then `time.advance(4)`; `expand.performClick(nil)`; `refresh().value`. Vacuity: `text.frame.height > scroll.frame.height`. `text.scroll(.zero)`: line 1's fragment rect is inside `text.visibleRect`; scroll to bottom: line 14's is. Mutant: `place()` sets the text height to `body` ⇒ line 14 unreachable ⇒ red.
8. **`testBarClickNeverTakesTheKeyboardButTextClickDoes`** (`requireUnlocked()` first). `say` an old line, advance 30. Record `NSWorkspace.shared.frontmostApplication?.processIdentifier`. `click` at the centre of `expand`: `refresh().value` ⇒ `text.string == "Old line."` (the action fired through the real dispatch) and `panel.isKeyWindow == false`. `click` inside the first line fragment ⇒ `panel.isKeyWindow == true`. Frontmost pid unchanged. Mutants: `becomesKeyOnlyIfNeeded = false` ⇒ first key assertion red; `BarButton.acceptsFirstMouse` false ⇒ action red; `CaptionText.needsPanelToBecomeKey` false ⇒ second key assertion red.

Each mutant: one edit, the named test red, revert, green.

## Steps to attain the human-verifiable result
1. Edits; `./test.sh Bar` (1–7 anywhere with a display; 8 unlocked) green; `./test.sh Overlay` and `./test.sh Attach` still green.
2. Mutants.
3. **Human gate.** The S11 gate setup (QuickTime playing `conversation.wav`, attached from the menu). Minh drags the overlay by the grip, clicks ⌃ (older lines appear, scroll), clicks the eye (captions vanish, crossed eye stays), clicks it again, hides and shows from the status menu, and types in TextEdit throughout without losing keyboard focus.
4. Fresh adversarial review.
