# Stratum 13 Blueprint — Highlight and copy

Written together with S11 and S12. Extends `Overlay.swift` (S11 shapes: `CaptionText`, `draw()`, `refresh()`, `userChange()`, `text`, `panel`; S12 shapes: `toggleCaptions`, `expand`) and `OverlaySupport.swift` (`OverlayRig`, `click`). Resolves the OTHER.md item "S13: gate also tries dragging selected text" and, with S12's `userChange()`, the deferral "hiding the captions while a selection exists leaves the hold on".

# Uncertainties squashed

1. **A text replacement destroys the selection and notifies** (S11 item 2), so a data-driven draw must not write while a selection exists. Programmatic selection never scrolls (probe `/tmp/te-ovl-probe/s.swift`: clip stayed at y 212 through `setSelectedRange` to `{0,0}`, `{5,4}`, `{0,0}`).
2. **Copy.** `writeSelection(to: pb, types: text.writablePasteboardTypes)` returns true and writes the selected substring; `writeSelection(to:type: .string)` returns false (probe `q.swift`). `NSTextView.copy(_:)` writes to the general pasteboard, so no test calls it; Edit ▸ Copy (nil target, first responder of the key window) is what ⌘C reaches, and the test asserts that item's wiring. Minh's probe and the human gate cover the keystroke.
3. **`dragSelection(with:offset:slideBack:)` is overridable** (`NSTextView.h:315`; compiled in probe `s.swift`). Returning false means selected text cannot be dragged out; stock `NSTextView` writes the selection to the drag pasteboard when a drag begins, which is test 6's observable.
4. **Resign key is `NSWindow.didResignKeyNotification` with `object: panel`**, the exact input the code receives, so the test posts it. Whether AppKit sends it when the user clicks into another app with a non-activating panel is the human gate.
5. **Mouse-down hold.** `NSTextView.mouseDown` runs its tracking loop inside the call, so a flag set around `super.mouseDown` is true exactly for the press, with no timer. No in-process test can land a draw inside the loop deterministically: this clause is verified by the human gate only.
6. **Only data-driven draws hold.** Store changes and expiry hit the hold. User changes (hide/show, expand, config) call `userChange()` (S11), which collapses the selection first, so they are never held. The bar note and the panel height are not text writes and always apply.
7. **One owner of `NSApp.mainMenu`: `Overlay`.** An accessory app needs no other main menu; the hidden one exists only so ⌘C resolves (Minh's real mouse, DECISIONS).
8. **Termination.** An observer-triggered draw either writes text (the selection collapses and the observer fires once more, finding `held == false`) or finds equal text and writes nothing.

# Blueprint

Edited: `Sources/TEUI/Overlay.swift`, `Tests/TECoreTests/OverlaySupport.swift`. New: `Tests/TECoreTests/SelectionTests.swift`.

## `Overlay.swift`

`CaptionText` (S11) gains:
```swift
var pressed = false                   // true exactly while a mouse press is being tracked
var onRelease: (() -> Void)?
override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }     // the first click selects; it does not just make the panel key
override func mouseDown(with e: NSEvent) { pressed = true; super.mouseDown(with: e); pressed = false; onRelease?() }
override func dragSelection(with e: NSEvent, offset: NSSize, slideBack: Bool) -> Bool { false }   // highlight-and-copy only
```

`Overlay` gains:
```swift
private var held = false      // a data-driven text write was skipped and is owed
private var holding: Bool { text.pressed || text.selectedRange().length > 0 }
private func releaseIfHeld() { if held && !holding { refresh() } }
```
Two replacements in S11's `draw()`:
- `writeText(r, config)` becomes `if holding { held = true } else { held = false; writeText(r, config) }`
- `if follows {` becomes `if follows, !held {`

In `init`, after the views exist:
```swift
text.onRelease = { [weak self] in self?.releaseIfHeld() }
NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: text, queue: nil) { [weak self] _ in
    MainActor.assumeIsolated { self?.releaseIfHeld() }
}
NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: nil) { [weak self] _ in
    MainActor.assumeIsolated { self?.text.setSelectedRange(NSRange(location: 0, length: 0)) }   // fires the observer above
}
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")          // target nil: first responder of the key window
let editItem = NSMenuItem(); editItem.submenu = edit
let main = NSMenu(); main.addItem(editItem); NSApplication.shared.mainMenu = main
```
`queue: nil` delivers synchronously on the posting thread (AppKit posts on main), so a test that posts the resign notification sees the selection already cleared. Cost: while nothing is held, neither observer ever draws (`held` is false).

## `OverlaySupport.swift` edit
`OverlayRig.seed()` (`@MainActor`): `attached = {A}`; `say("A","Hello there.")`, `say("A","Second line.")`; `refresh().value`; the string is `"Hello there.\nSecond line."`. `selectThere()`: `text.setSelectedRange((text.string as NSString).range(of: "there"))`. `drag(_ panel: NSPanel, from: NSPoint, to: NSPoint)` (window points): `NSApp.postEvent` a `leftMouseDragged` at `to`, then a `leftMouseUp` at `to` (both `atStart: false`), then `panel.sendEvent(leftMouseDown at from)`; S12's `click` is the same with no drag event.

## `Tests/TECoreTests/SelectionTests.swift` (`@MainActor final class SelectionTests`, category Selection)
1. **`testCopyWritesExactlyTheSelectionAndCommandCIsWiredToTheResponderChain`.** `seed`; `selectThere()`. `pb = NSPasteboard(name: .init("te-sel-" + UUID().uuidString))` (`releaseGlobally()` in teardown). `text.writeSelection(to: pb, types: text.writablePasteboardTypes)` is true and `pb.string(forType: .string) == "there"`. `NSApp.mainMenu!.items[0].submenu!.items` has one item: title `"Copy"`, `action == #selector(NSText.copy(_:))`, `keyEquivalent == "c"`, `keyEquivalentModifierMask == .command`, `target == nil`. Mutant: no main menu ⇒ red.
2. **`testDataArrivingWhileSelectedLeavesSelectionAndTextUnchanged`.** `seed`; `selectThere()`; `say("A","Third line.")`; `refresh().value`. `text.string == "Hello there.\nSecond line."` and `selectedRange()` equals the range chosen. Mutant: remove the hold ⇒ text changes ⇒ red.
3. **`testDeselectCatchesUpWithoutAnyOtherEvent`.** After 2: `text.setSelectedRange(NSRange(location: 0, length: 0))`; `eventually("catch-up") { text.string == "Hello there.\nSecond line.\nThird line." }` (no `refresh()` call, so only the selection observer can cause the draw). Mutant: delete the `didChangeSelection` observer ⇒ times out ⇒ red.
4. **`testResignKeyClearsTheSelectionAndShowsTheLatestLines`.** `seed`; `selectThere()`; `say("A","Third line.")`; `refresh().value` (unchanged); post `NSWindow.didResignKeyNotification` for `overlay.panel`; `text.selectedRange().length == 0` immediately; `eventually("latest") { text.string == "Hello there.\nSecond line.\nThird line." }`. Mutant: delete the resign observer ⇒ stale ⇒ red.
5. **`testUserActionsEndTheSelectionAndAreNeverHeld`.** `seed`; `selectThere()`; `say("A","Third line.")`; `refresh().value` (held). `overlay.toggleCaptions()` (hide): `text.selectedRange().length == 0` and `eventually { panel.frame.height == 28 }`. `overlay.toggleCaptions()` (show): `eventually { text.string == "Hello there.\nSecond line.\nThird line." }`. Mutant: `toggleCaptions` calls `refresh()` instead of `userChange()` ⇒ the selection survives the hide, the show is held, the text stays stale ⇒ red.
6. **`testSelectedTextCannotBeDraggedOut`.** `seed`; `selectThere()`. (a) `text.dragSelection(with: <a leftMouseDragged event>, offset: .zero, slideBack: false) == false`. (b) After `requireUnlocked()`: clear `NSPasteboard(name: .drag)`; `drag` from the centre of the selected word (`layoutManager.boundingRect(forGlyphRange:)` ⇒ `text.convert(_, to: nil)`) to 40 pt right of it; afterwards `NSPasteboard(name: .drag).string(forType: .string) == nil`. Mutant: delete the override ⇒ (a) or (b) red. Settled at build: if the mutant leaves both green the test is vacuous; stop and report.
7. **`testRealDragSelectsOnTheFirstClickAndHoldsUntilResign`** (`requireUnlocked()` first). `seed`; record the frontmost app's pid. `p1` = window point 6 pt inside the first line fragment's left edge at its mid-height; `p2 = p1 + (100, 0)`. `drag(panel, from: p1, to: p2)` (the panel is not key yet). `text.selectedRange().length > 0`, the selected substring is a non-empty prefix of `"Hello there."`, `panel.isKeyWindow`, frontmost pid unchanged. `say("A","Third line.")`; `refresh().value` ⇒ text unchanged. Post resign ⇒ `eventually` the text has three lines. Mutants: `acceptsFirstMouse` false ⇒ the first click only makes the panel key ⇒ selection empty ⇒ red; `needsPanelToBecomeKey` false ⇒ `isKeyWindow` red.

Each mutant: one edit, the named test red, revert, green. Tests 1–5 and 6(a) run on any host with a display; 6(b) and 7 need the unlocked Mac.

## Steps to attain the human-verifiable result
1. Edits; `./test.sh Selection` green on mac-work-2 unlocked; `./test.sh Overlay` and `./test.sh Bar` still green.
2. Mutants.
3. **Human gate** (S11's setup: QuickTime playing `conversation.wav`, attached from the menu, TextEdit open with an empty document). Minh: clicks ⌃; scrolls up with the wheel; selects a caption line with the real mouse; ⌘C; pastes into TextEdit (the paste equals the selection, and the captions behind it did not move while it was selected); tries to drag the selected text onto TextEdit (nothing happens); presses the mouse on a caption and holds without moving (the text does not shift under the pointer); clicks elsewhere (captions resume and the selection is gone); and the frontmost app never changes.
4. Whole `./test.sh` green, then fresh adversarial review.
