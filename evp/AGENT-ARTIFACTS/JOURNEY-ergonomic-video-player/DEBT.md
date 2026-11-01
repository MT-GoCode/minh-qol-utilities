# DEBT (rewritten 2026-11-01; each item is open or an accepted limit)

## Needs Minh
- `/usr/local/bin/rac` is missing. Fix needs a sudo password: `sudo ln -sf /usr/local/bin/remote-agent-connector /usr/local/bin/rac`.
- Something on mac-work-2 (likely SentinelOne) deletes executable files in git working trees. Restored from git each time. A watchdog was not built: it would fight a security tool on a work laptop, so that is his call.
- Hand checks, because no automated test reaches them: synthetic mouse events do not reach the app, so hovering, clicking and dragging the strip and double-clicking the time; thumbnails; real held-key autorepeat (macOS drops synthetic repeats); the event tap (injected events skip taps).
- Media-key and full-screen E2E are opt-in (`EVP_E2E_MEDIA=1`, `EVP_E2E_FULLSCREEN=1`) and were not run at close-out: media keys reach the whole system and need Chrome, Music and Spotify closed; full screen takes over the display. They count as passes in the xunit totals when skipped. The F8 resume route is covered only by these and by hand.

## Unexplained
- `E2EKeysTests.testSpaceTogglesOnceEvenWhenAButtonHasFocus` failed once in a full run on `fce2b8a`: about 0.7 s after one space press the message read "Playing", so a second toggle arrived from somewhere. It then passed 10 of 10 alone and in a clean full run. The source is not known. A key pressed by hand would explain it, and so would a system media command; neither is confirmed. If a paused video ever resumes by itself, start here.
- `E2ETimeTests.testARelativeTimeMovesFromWhereItIs` failed once in an earlier full run (typed `-3` did not reach the time field) and passed 3 of 3 alone. The helper already waits for the field to be editing, so the cause is not known.

## Accepted limits, each left on purpose
- Rendering and blocking mpv calls share the main thread. Moving them is a redesign with no measured problem behind it.
- An mpv event queue overflow stops the app: events lost would corrupt saved positions. Never seen; wakeups now coalesce.
- `prepareOpenGL` stops the app if AppKit recreates the GL context. It never has, and a recovery path would be code nobody has seen run.
- A launch whose files all fail leaves the app running with no window, the same as a launch with no files. The alert already reported the failure and File > Open still works.
- A taken global hotkey alerts at every launch. A failure stays visible rather than silently leaving the key dead.
- `state.json` is rewritten whole on each flush and `files`/`recents` never shrink. Remembering every file is the feature; any cap would be an invented number.
- `FileState` and `Frame` decode strictly (a new field needs a version bump). One malformed chord in a hand-edited keymap refuses the whole file: the app never replaces state it cannot read.
- A sidecar subtitle reads "English - en.srt": the test states this on purpose, because the file name says which one it is. An unknown language code shows as the raw code.
- `KeyChord` and the global hotkey know US-layout key codes only.
- A chord the menu bar owns (Cmd+O, Cmd+Q) can be bound but never fires. A refusal was built and removed: no test can reach it while the app is in the background, and it wrongly refused plain `e` (the system's fn+E Emoji item).
- A window saved on a screen that is gone: AppKit brings it back on screen by itself (seen in a test run with the fix removed), so EVP has no code for it.
- The two preview and key-recorder fixes of review round 10 (a late error no longer blanks the next hover; a held key never records itself) have no automated test: only a real hover and real autorepeat reach them.
- The `jumpN` actions are listed in four places: a payload case would rename the stored keymap keys.
- With video A paused and main and B playing behind it, F8 acts on A: the rule is the main window, and Minh set no other.
- Thumbnails come from the nearest keyframe, so on long-GOP files they can be several seconds off the hovered time. Exact seeks would decode far more on every pointer move.
- A seek that gets neither a restart nor an error would leave the preview waiting: no known trigger, and a test covers the end of the file, a repeated time and time 0.
- `previewFailed` (drop and retry on the next hover) has no test: only a real hover reaches it.
- Tests: the "window leaves Ctrl+Space alone" check detects the regression through the window's `preconditionFailure`; `E2EMemoryTests` reads the paused state of the first restored window only; `Tools/make-fixtures` keeps an existing file whatever its recipe; `results/` is never pruned; `evpdrive` keeps its own key table.
