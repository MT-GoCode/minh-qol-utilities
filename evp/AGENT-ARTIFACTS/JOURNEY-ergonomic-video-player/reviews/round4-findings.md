# EVP review, round 4 (headless, copy at /tmp/evp-review5/evp)

Build: `swift build --build-tests` OK. `swift test --filter 'Unit|Integration' --skip IntegrationCli --skip IntegrationDriver`: 108 tests, 0 failures. E2E read, not run.
Result: no HIGH, no MEDIUM.

## Round 3 items
- M-A (ctrl+space check): FIXED, indirectly. `PlayerWindowController.swift:152` is now `preconditionFailure`. With the mutant (drop `!Action.global.contains(action)` at `:129`) ctrl+space crashes the app, and `E2EKeysTests.swift:51` then times out. The test still has no direct assertion (see L1).
- L-A (dead `pauseAll` case, stale message): NOT FIXED in substance. The message is gone, but `Command.action(.pauseAll)`, `InterfaceAction.pauseAll` (`MpvPlayer+Commands.swift:5,70`) and a crash arm (`:152`) remain. A representable but unreachable command that kills the app (L1).
- L-C (speed step the engine rounds away): FIXED. `Settings.swift:49` requires `>= 0.01`; `UnitSettingsTests.testASpeedStepTheEngineWouldRoundAwayIsRefused` covers 0.005 and 0.01.
- L-D (recorder routes on strings): FIXED. `KeyRecorderField.swift:7-8,53-57` compares against `KeyChord` values.
- L-F (`scratch` not created with `home:`): FIXED. `E2ESupport.swift:158` creates `scratch` itself.
- L-G (`"w":260`): FIXED. `E2ESupport.swift:191` now skips only zero-width windows.
- L-H (`XCTAssertNotNil` on a String): FIXED. `E2ETimeTests.swift:84,86` use `_ =`.
- L-L (red message never cleared): FIXED. `SettingsWindowController.swift:80` clears it in `windowWillClose`.
- Accepted as debt, unchanged: L-B (`ControlBar.swift:118` `%.1fx` vs feedback `%g`), L-E, L-I, L-J, L-K.

## LOW (new, most severe first)

### L1. `E2EKeysTests.swift:48-52` and `PlayerWindowController.swift:152`: the only detector of "window consumed the global chord" is a crash
The test passes or fails on whether the app survives. Any later softening of `preconditionFailure` (a log, a no-op) turns the check silently green again, as in round 3. Principle: exact, not exhaust; make illegal states unrepresentable. Fix: remove `pauseAll` from what `MpvPlayer.perform` can return (the global action is not an `InterfaceAction`), and read `feedback` right after ctrl+space and assert it is unchanged.

### L2. `E2EBarTests.swift:55-56` the speed-reset check cannot fail for "reset does nothing"
Speed is already 1x, so feedback `Speed 1x` (read from the engine) and the title `1.0x` are the same with or without a working reset. Only the button-to-command mapping is tested. Mutant: make `speedReset` a no-op: green. Fix: change speed first (key `d`), then press `speed`. Also `:52` (`< 8` after +10 then -5) holds only if the pause happened before 3 s; a slow `rac exec` makes it flaky.

### L3. `KeyRecorderField.swift:44-47` `startRecording` ignores the result of `makeFirstResponder`
If the current responder refuses to resign, `recording` is true while the field is not first responder: no key arrives, `resignFirstResponder` never runs, and on the Global tab the hotkey stays unregistered until the recorder is used again. `windowDidResignKey` and `windowWillClose` do not help (they resign the real first responder). Fix: `recording = window?.makeFirstResponder(self) == true`.

### L4. `KeyRecorderField.swift:49-51` a held recorded key restarts recording
After the chord is recorded, `recording` is false and auto-repeat key-downs go to `super.keyDown`; an `NSButton` treats space as a click, so holding space (or ctrl+space) may re-enter recording and leave "Press a key…" shown. Hedged: not run. Fix: ignore `event.isARepeat` in `keyDown` regardless of state.

### L5. `KeyRecorderField.swift:60-65` + `PlayerWindow.swift:11` chords that can be recorded but never fire (or steal the system)
Recording takes any chord including cmd+q, cmd+m, cmd+w, cmd+, , cmd+o. For a Keybinds action the main menu's key equivalent wins before `PlayerWindow.sendEvent`, so the binding is accepted and does nothing. On the Global tab `cmd+q` is accepted (`Settings.swift:54` only needs a modifier) and registers system-wide, taking Quit from every app. Principle: validate at the boundary what the core cannot honour.

### L6. `SettingsWindowController.swift:239,200-201` a stale red message survives a no-op or unrelated change
`guard new != old else { return refresh() }` and the "not a number" path leave the previous message in place; a refusal stays on screen after the user fixes something else, until success or close. Cosmetic. Principle: single source of truth for what is shown.

### L7. `Tools/evpdrive.swift:201-207` `screen(to:)` ignores the exit status that `snapshot` checks
When `screencapture` fails (display asleep), `terminate()` in `E2ESupport.swift:190-198` reports a path to a screenshot that does not exist. Also the usage string (`:233`) omits `tree` and `snapshot-screen` that the header documents. Principle: failures must not look like success.

### L8. `E2ELaunchTests.swift:15` `XCTAssertEqual(try app!.windowCount() > 0, true)`
Always true once the earlier `waitForSnapshot` found a window; observes nothing. Principle: non-tautological tests.

### L9. `GlobalHotkey.swift:46` signature `0x45565031` has no stated origin
Four-character code `EVP1`; a one-word comment or a named constant removes the "arbitrary constant" tell. Cosmetic.

## Checked and sound
Hotkey swap order in `accept`/`holdGlobalHotkey` (hold ends, then commit registers the new chord; refusal re-registers the old one); `Settings.problems` NaN/inf; `resetAll` keeps the global chord and cannot conflict (defaults carry no modifiers); `SessionRegistry` termination vs user close; E2E teardown order (state folder removed after quit); `./test` status plumbing under `pipefail`, `caffeinate -d` on both E2E branches; `close:` driver path; stale-feedback risk in `key(...expectFeedback:)` (no test expects a text equal to the previous one).

## Verdict
No HIGH. No MEDIUM. Round 4 returns clean per the review rule; L1 to L3 are worth taking before the next change to those files.
