# EVP review, round 3 (reviewer run 4). Working tree reviewed in a copy at /tmp/evp-review4/evp.

Build: `swift build --build-tests` OK. `swift test --filter 'Unit|Integration' --skip IntegrationCli --skip IntegrationDriver`: 107 tests, 0 failures.
No HIGH. One MEDIUM. E2E tests were read, not run (per constraints).

## Status of the previous round
`/tmp/evp-review3/findings.md` does not exist (no /tmp/evp-review3, no copy anywhere under the journey folder). M1 to M4 and L1 cannot be judged: their text is not available. Say so; do not take "unverified" as FIXED.
Items that DEBT.md/DECISIONS.md name closely enough to check against the code:
- L2 (`./test --filter Unit` needs rac and builds the app): NOT FIXED. `test:16-20` preflights `rac` and runs `scripts/build.sh` before looking at arguments.
- L3 (pause-all second press): FIXED. `PauseAll.press` resumes only remembered players still paused, else pauses what plays (`PauseAll.swift:27-39`).
- L4 (AZERTY digits, US key codes): NOT FIXED, in DEBT (`KeyChord.swift` `characterKeyCodes` US only; `chord(...)` uses `charactersIgnoringModifiers`).
- L5 (jump cases in several places, `?? 0`): NOT FIXED. `MpvPlayer+Commands.swift:62` still has `action.jumpFraction ?? 0`; `jump0...jump9` still listed in `Action.jumps`, `repeatsWhenHeld`, `Keymap.defaults`, and the `perform` case list.
- L10 (renderer teardown on main thread): NOT FIXED, by design (`PlayerWindowController.windowWillClose` -> `video.shutdown()`).

## MEDIUM

### M-A. `E2EKeysTests.swift:48-53` the ctrl+space check cannot fail for the defect it names
The comment says the window "must leave it alone". Mutant: delete `!Action.global.contains(action)` in `PlayerWindowController.handleKey` (`:129`). Then `perform(.action(.pauseAll))` runs, `MpvPlayer.perform` returns `.interface(.pauseAll)`, and `performInterface` only sets the feedback "pauseAll is not available yet" (`:152`). The test then presses `m`, waits for feedback `Unmuted` (overwrites the text) and compares `play-pause` with `before`. Nothing in the mutant changes either, so the test stays green. The only assertion that distinguishes the two is absent (for example: feedback must be `Muted`-chain only, or `pauseAll`-feedback must never appear between the two keys).
Concrete failure: a regression that makes the window consume the global chord ships green.
Principle: test design, exact not exhaust (mutation-test each test). Fix by reading `feedback` right after `ctrl+space` and asserting it is unchanged from before (the ordering marker is the following `m`).

## LOW

### L-A. `PlayerWindowController.swift:152` and `InterfaceAction.pauseAll` (`MpvPlayer+Commands.swift:5,69`): dead case with a stale message
`handleKey` filters global actions; no bar button or menu sends `.pauseAll`. The only way to reach "is not available yet" is the mutant above. A representable-but-unreachable command (`Command.action(.pauseAll)`) plus a user-visible lie is cruft. Principle: no stale parts; make illegal states unrepresentable.

### L-B. `ControlBar.swift:118` bar speed rounds to one decimal, the feedback does not
`String(format: "%.1fx")` on the bar vs `"Speed %gx"` in `MpvPlayer+Commands.swift:84`. `Settings.problems()` accepts any `speedStep > 0`: a step of 0.25 shows 1.25 as `1.2x` on the bar and `Speed 1.25x` in the feedback; 0.05 makes two different speeds look the same. Principle: single source of truth for the displayed value.

### L-C. `Settings.swift:48` + `MpvPlayer.swift:adjustSpeed` accept a speed step the engine rounds away
`adjustSpeed` rounds to 2 decimals, `problems()` allows `speedStep = 0.001`: every press computes the same speed, shows `Speed 1x`, and nothing moves. Refuse steps below 0.01 in `problems()` (the rounding is the engine's rule). Principle: validate at the boundary what the core cannot honour; no silent no-ops.

### L-D. `KeyRecorderField.swift:50-53` routes on `pressed.description` strings
`"escape"` and `"delete"` are re-derived from a string. Compare against `KeyChord("escape")`/`KeyChord("delete")` once (mark, then route; exact). A chord such as `shift+delete` is correctly not matched today only because the string happens to differ.

### L-E. `E2EMemoryTests.swift:59` asserts the paused state of one window
`read("play-pause")` returns the first element found in the tree. The test name and message talk about every restored window ("reopening is silent"); a second window that starts playing passes. Likewise the positions of window 2 are never read. Read both windows (or assert through `press`/`read` per window).

### L-F. `E2ESupport.swift:156-157,300` `snapshot` fails when a test passes `home:`
`scratch` is only created as a side effect of creating `scratch/home`. With an explicit `home`, `scratch` is never created, so `snapshot(_:)` writes into a missing folder and `screencapture` fails. No current test combines the two (Settings, Memory do not snapshot); the next one will hit it. Create `scratch` explicitly in `launch`.

### L-G. `E2ESupport.swift:190` unexplained constant `"w":260`
Selects windows to screenshot on a failed quit. Origin undocumented (probably an NSAlert width); Settings is 560 wide and players are larger, so on a hang caused by Settings or a player nothing is captured. Principle: no arbitrary constants.

### L-H. `E2ETimeTests.swift:84,86` `XCTAssertNotNil` on a non-optional `String`
Always true; the real check is the throwing `wait`. Replace with `_ =` so the line does not read as an assertion. Tautological assertion (principle: test design).

### L-I. `E2EMediaKeysTests.swift:27-29` the "decoupled: F9 did nothing" check has no ordering marker
System media events travel through the window server, so reading `feedback` right after `media(17, 16)` can run before a (wrongly) delivered key arrives; absence is asserted without a following in-order key. Also, with EVP decoupled the keys go to the system, which may launch Music. The test is opt-in, so it runs only when someone remembers (principle: single suite, nothing that runs only on memory); the same holds for `testFullScreenKeepsTheBarBelowTheVideo`.

### L-J. `PauseAll.swift:35` one throwing `isPaused()` aborts the first press half way
`for player in players where try !player.isPaused()` throws on the first bad player; players already paused stay in `remembered`, the others keep playing, and the next press resumes the partial set instead of pausing the rest. Edge case; only matters if a player errors on `pause`.

### L-K. `AppDelegate.swift:140` + Settings panel
`applicationShouldTerminateAfterLastWindowClosed` is true, but an open Settings panel is a visible window, so closing the last video leaves the app running with only Settings. Quitting is then Cmd+Q only. Cosmetic.

### L-L. `SettingsWindowController.swift` red message is never cleared on close
`message` keeps the last refusal after the panel is closed and reopened (`windowWillClose`/`windowDidBecomeKey` only call `refresh()`). Cosmetic, but it reads as a live error.

### L-M. Stale entries in DEBT.md (and RESUME.md)
Still listed though no longer true: "`Settings.problems()` exists but nothing calls it" (`SettingsWindowController.commit` and `AppDelegate` call it); "install.sh --prebuilt has no staleness check (L19)" (`install.sh:41-42` refuses a stale app); "no Edit menu so Cmd+C and Cmd+V fail in the time field (L11)" (`MainMenu.swift` has Edit); "Strata 8 to 13 ... have not run once", "nothing in it has run in a real app yet" (E2E has run on the real screen). Principle: no stale parts.

### L-N. `AppDelegate.swift:76,183` modal alert from the hotkey registration
A saved global chord that another app now owns shows a modal `NSAlert` at every launch and blocks window restore. Show it in the window bar or Settings instead (the bar path already exists, `showFeedback`). Cosmetic.

## Checked and found sound (no action)
`GlobalHotkey` swap/unregister order, `accept`/`holdGlobalHotkey` ordering (hold ends before the commit, refusal re-registers the old chord), recorder ending on resign/close, `Settings` validation of NaN/inf, `commit` refusal path restores controls, `test` script status plumbing under `pipefail`, `install.sh`/`uninstall.sh` idempotence, E2E teardown order (state folder removed after quit), evpdrive cycle-safe tree walk.

## Verdict
No HIGH. One MEDIUM (M-A). Fix M-A, then a new fresh reviewer round is needed per the review rule; the round-3 text itself was not available, so M1 to M4 remain unverified.
