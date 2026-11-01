# Round 10 review of HEAD 493321d

## MEDIUM

### M1. A stale async preview error blocks the whole next hover
`evp/Sources/EVP/PlayerWindowController.swift:122-146` (`scrubHovered`, `previewFailed`). Principles: single owner for mutable state, robustness in edge cases.
- `previewFailed` is also the `FramePreview.onError` callback, which runs asynchronously (`:132`).
- Trigger: hover the strip, leave (`scrubHovered(nil)` sets `previewBroken = false`), and then the decoder error arrives. This is the likely order for a slow-failing file.
- The late error sets `previewBroken = true` after the reset. The next hover then hits `guard !previewBroken` and returns silently, with no bubble and no retry.
- The comment says "the next hover tries again". Only the hover after that does.
- Fix: clear the flag where a hover starts, not only where one ends. Or ignore errors from a preview that is no longer `self.preview`.

### M2. KeyRecorderField records the repeat of the key that started the recording
`evp/Sources/EVP/KeyRecorderField.swift:50`. Principle: robustness in edge cases.
- The new guard is `recording || !event.isARepeat`, so repeats pass while `recording` is true.
- The comment on the guard says the button's action fires on the key-down. So holding Space or Return on the focused recorder starts recording on the first key-down.
- The next auto-repeat key-down then arrives with `recording == true` and is recorded as `space` or `return`.
- Trigger: a press longer than the key-repeat delay. The guard covers only the repeat after the recording ended.
- Fix: `guard !event.isARepeat else { return }`, with no `recording ||`. A held key never records.

## LOW

### L1. menuTitle matches only plain-character key equivalents
`evp/Sources/EVP/SettingsWindowController.swift:196-203`. Principle: mark then route, exact checks.
- It never matches a menu key equivalent that is an AppKit function-key character, or a space.
  - Menu: `NSLeftArrowFunctionKey`, `" "`. Chord: `left`, `space`.
- It misses an uppercase `keyEquivalent` (`"O"` means shift).
- It ignores `isHidden` and `isEnabled`. A hidden or disabled item with a matching chord is refused.
- None of this affects the current menu. The only item checked is `o` with the default command mask.
- It also gives false negatives for any future menu item that binds an arrow key.

### L2. The comment on record() has the event order wrong for the recorder itself
`SettingsWindowController.swift:188`. Principle: minimal comments, state the true property.
- "before any window sees them" is wrong. The key window's `performKeyEquivalent` runs first, and `KeyRecorderField` relies on that.
- It is right for the player window's `keyDown` bindings. Narrow the comment to that.

### L3. Off-screen restore accepts any intersection
`PlayerWindowController.swift:57`. Principle: robustness in edge cases.
- A saved frame that overlaps a screen's `visibleFrame` by 1px counts as reachable and is not centered.
- The check does not require the title bar to be reachable.
- It also centers on the main screen, not the screen nearest to the old frame.

### L4. A partial pause-all failure turns the next press into a resume
`PauseAll.swift:36-48`. Principle: robustness in edge cases.
- After a press that throws, `remembered` holds the videos that did pause, so the next press resumes them.
- The broken video is not retried, and the user cannot pause the rest again.
- The semantics are documented and tested, but the docstring does not say that the press after a failure resumes.

### L5. The off-screen E2E test compares AX and AppKit coordinates
`E2EMemoryTests.swift:94`. Principle: test design, exact checks.
- The driver reports top-left-origin coordinates. `NSScreen.frame` is bottom-left-origin.
- The union check is loose with several vertically stacked displays.
- The x = 100000 case still fails without the fix, so the test is valid for the defect it names.

## Checked, no defect

- **WakeBox coalescing.**
  - Order: `pending` is set true under the lock in `wake()`. The queued block clears it under the lock *before* `drain()`.
  - Stranding: any event after the clear sees `pending == false` and schedules another drain. An event before the clear is read by the `drain()` that follows, because `drain()` loops to `MPV_EVENT_NONE`. So no event is stranded.
  - Lock: held only for the flag read or write, never across `drain` or `main.async`. The main thread never holds the box lock while calling into mpv. So there is no lock-order inversion with mpv's wakeup lock.
  - Lifetime: the queued block captures the box strongly, so `wake.release()` in `deinit` cannot free it under a pending block. `player` is weak, so a late block is a no-op. `mpv_set_wakeup_callback(nil)` takes mpv's wakeup lock, so no callback is in flight at release.
  - The render update callback (`:178`) is detached before the release, and is unchanged.
- **PauseAll.**
  - Resume path: unchanged.
  - Pause path: `isPaused` throws are also caught per player.
  - The new test fails if the `catch` is reverted, because `last` would not be paused. Its second press checks that the `remembered` set is exactly {first, last}.
- **KeyRecorderField `makeFirstResponder`.** `recording = makeFirstResponder(self) == true` is correct. A refusal leaves `recording` false. An already-first-responder window returns true.
- **Scrub hooks.**
  - `scrubHovered(nil)` is safe from `windowDidResize`, the fullscreen hooks and `windowWillMiniaturize`. It is idempotent, and `bubble` and the flag are initialised before the delegate fires.
  - Removing the hide from the `.fullscreen` case is covered by `windowWillEnter/ExitFullScreen`. That also covers the green button and the menu item.
- **New tests.** They name real defects. The pause-all, speed-label, menu-refusal and off-screen tests go red when the fix is reverted.
  - `IntegrationPreviewTests` `guard got.count == 5` only avoids an index crash after the earlier assertion has already failed.
  - `testCheckFailsExactlyWhenAPermissionIsMissing` compares against the same permission calls the driver makes. It is an agreement test. It is not tautological, because the driver is a separate process.

VERDICT: FINDINGS
