# Round 11 review of `git diff HEAD~2 HEAD`

Both round 10 MEDIUMs are fixed. The menu-chord refusal and the off-screen restore left nothing behind: `menuTitle`, `visibleFrame`, the off-screen E2E test and the README text are all gone (grep over Sources, Tests and README finds no trace).

## MEDIUM
None.

## HIGH
None.

## LOW

### L1. `MediaKeys.refresh` docstring is stale
`evp/Sources/EVP/MediaKeys.swift:36`. Principle: no stale parts, minimal comments that state the true property.
- It says "Call whenever a window starts or stops playing, opens or closes, or the decoupling changes".
- The diff adds a fourth trigger: a window becomes or resigns main (`PlayerWindowController.swift:173-175`). `onMediaStateChanged` says so; `refresh` does not.

### L2. A late preview error after the window closed still runs UI code
`PlayerWindowController.swift:103` and `:143-148`. Principle: robustness in edge cases.
- `windowWillClose` sets `preview = nil`, but the `FramePreview` it owned may still deliver `onError`.
- `previewFailed` then calls `bar.showFeedback` on a closed window. It is harmless: `self` is weak and the bar object still exists.
- No concrete defect, so LOW.

### L3. `previewBroken` blocks retries for the rest of one hover
`PlayerWindowController.swift:126-128`. Principle: robustness in edge cases.
- If the error lands while the pointer is still on the strip, the preview stays off until the pointer leaves and re-enters. This is documented in the field comment, and the error is shown once, so it is not a silent failure.
- Trade-off against retrying on every mouse-move (a new decoder per move). The choice is sound.

## Checked, no defect
- **M1 fix.** The reset sits at hover start (`hoverTop == nil`). An error after the pointer left sets the flag, and the next hover clears it. `scrubHovered(nil)` from resize, full-screen, miniaturize and toggleBar never touches the flag, so a hover that never ended cannot be reset. `FramePreview.onError` firing once is covered by the test's 0.5 s duplicate window.
- **M2 fix.** `guard !event.isARepeat` comes before the `recording` check, so a held key never records. The guard also drops repeats when not recording, which `super.keyDown` did not need. `performKeyEquivalent` goes through `keyDown`, so it gets the same guard. `recording = makeFirstResponder(self) == true` is correct.
- **WakeBox.** `defer { pending = true }; return !pending` reads the old value, then sets it. The queued block clears `pending` before `drain`, so no event is stranded. The block holds the box strongly and `player` is weak. Unchanged from round 10.
- **PauseAll.** The per-player `do/catch` keeps the rest running and rethrows the first error. The remembered set holds exactly the players that did pause. The docstring now states that the press after a failure resumes them. The new test goes red if the `catch` is removed.
- **Speed label.** `%.2f` then drop one trailing `0`: 1 gives `1.0x`, 1.3 gives `1.3x`, 1.25 gives `1.25x`, 0.05 gives `0.05x`, 100 gives `100.0x`. All cases are in the unit test. `ControlBar.setSpeed` uses it; no other `%.1fx` is left.
- **`onPlayingChanged` rename.** No remaining references. The `.fullscreen` hide moved into `windowWillEnter/ExitFullScreen`, which also covers the green button.
- **New tests.** `testCheckFailsExactlyWhenAPermissionIsMissing` is an agreement test against a separate process, not a tautology. `guard got.count == 5` only avoids an index crash after the earlier assertion has already failed. The usage string in `evpdrive` now lists `check`, `tree` and `snapshot-screen`.

VERDICT: CLEAN
