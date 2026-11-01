# Round 8 findings (HEAD~1, HEAD)

## Answer to the focus question: dropping the preview inside its own onError is safe
Both paths keep the object alive until the call returns, so mpv_terminate_destroy never runs under a live mpv call.
- Event path: wake callback does `box.player?.drain()`. The weak load makes a strong reference held across the call, so the MpvPlayer outlives drain. `FramePreview.handle` is called through `self?.handle`, which also holds a strong reference for the call. `preview = nil` in `previewFailed` therefore only queues the release. FramePreview deinit and MpvPlayer deinit (mpv_terminate_destroy) run after drain returns, on the main queue, not under mpv_wait_event. The loop's next `mpv_wait_event(handle, 0)` still has a live handle.
- Synchronous path: `scrubHovered` -> `preview?.show` -> `next` -> `finish(.failure)` -> `onError` -> `preview = nil`. The stored property is retained for the call, and `finish` then calls `next()`, which returns at its guard (`wanted` was cleared). Safe.
- Late wake callbacks: they hit a nil weak `box.player` after deinit. Safe. The wake-callback lock comment in deinit still holds.
- Pending state: a loadFailed during `decoding != nil` or before `ready` is also routed through the drop, so no wait on a dead player remains. Round-7 MEDIUM (2) is resolved.

## Findings

### LOW — IntegrationPreviewTests.swift:73 — test crashes instead of failing (Test design, Robustness)
Trigger: the defect the test names (a seek with no restart). `got` has fewer than 3 entries, so the `XCTAssertEqual` on line 72 fails and `got[2]` on line 73 traps with index out of range (continueAfterFailure is on by default). The run dies and hides the other results. Guard with `XCTAssertEqual(got.count, 5)` plus `guard`, or use `try XCTUnwrap(got.dropFirst(2).first)`.

### LOW — IntegrationPreviewTests.swift:85-86 — duplicate error would go unnoticed (Test design)
The loop exits on the first error and asserts `count == 1` at once, so a second `loadFailed` for the same load would arrive after the check. Add the 0.5 s settle used elsewhere before asserting.

### LOW — PlayerWindowController.swift:137-142 — no test for the drop-and-retry (Test design)
`previewFailed` (new preview on the next hover, error shown again) has no test. The Core test covers the single error only. Revert the `preview = nil` and every test stays green. The AppKit target may not be unit-testable. If so, say so in DEBT.
Related: for a file the main player opens but the preview cannot, each pointer move after a failure builds a new mpv instance and shows feedback again. This is the retry-and-report behaviour chosen last round, so not raised above LOW.

### LOW — FramePreview.swift:36-62 — no mechanism if a seek yields neither restart nor end-file error (Robustness)
Round-7 MEDIUM (1) was answered with a test, not a mechanism. I cannot state a concrete trigger. mpv answers a seek with PLAYBACK_RESTART, with an error END_FILE (now handled by the drop), or with a command error (handled by `next`). Under `keep-open=yes` the end of file does not unload. The test (line 62-74: end of file, repeated time, time 0, 5 of 5) is falsifiable and covers the known edge cases, so I accept it. A decode that never returns would still hang with no watchdog. Any timeout needs a measured value, so defer it.

VERDICT: CLEAN
