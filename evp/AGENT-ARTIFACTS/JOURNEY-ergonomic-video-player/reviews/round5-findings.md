# Review 6 findings (6cc027f..ea07356, evp/)

Build and `swift test --filter 'Unit|Integration' --skip IntegrationCli --skip IntegrationDriver`: 111 tests, 0 failures.
Probe in the /tmp copy (not in the repo): a first show(15) before load equals a show(15) after load (no frame-0 race on t.mp4); show(duration) still delivers; a request during a decode is coalesced and the last one wins. Those three suspects are cleared.

## MEDIUM

1. EVP/PlayerWindowController.swift:118-135 + EVP/ScrubBar.swift:47-53 — the bubble is hidden only by `mouseExited`. Pressing Tab (hides the bar, `bar.isHidden = true` in PlayerContentView.layout) or toggling full screen while the pointer is on the strip hides or moves the strip without a guaranteed `mouseExited`. Failure: the thumbnail child window stays on screen until the pointer re-enters and leaves the strip. `toggleBar` and `fullscreen` in `performInterface` and key presses do not call `bubble.hide()`. Principle: single owner for mutable state / robustness (user edge case). Fix: hide the bubble (set `hoverTop = nil`) from `ScrubBar` when it is hidden or leaves its window, or from `performInterface`.

2. Tests/EVPTests/IntegrationPreviewTests.swift:28-31 — `testOnlyTheLatestRequestIsDecoded` sends all three requests before the file loads, so it only proves that `wanted` is overwritten. The case the code comment and decision promise (a request arriving during a decode replaces the waiting one) is not covered. Mutant: delete `decoding == nil` from the `next()` guard. Concurrent seeks are then issued, and the test still passes, since it only exercises pre-load assignment. Principle: tests load-bearing / falsifiable. Fix: show(2), then show(5) and show(15) once `decoding` has begun, and assert the delivered times are [2, 15].

## LOW

3. EVPCore/FramePreview.swift:42-44 — `decoding` clears only on `.playbackRestart` or a thrown seek. If mpv never sends `playbackRestart` for a seek (a failed demuxer seek on a damaged file, or a file that fails after load: `.loadFailed` sets no `decoding`), `decoding` stays non-nil and every later hover is silently ignored for the life of the window. Not seen to happen. After `.loadFailed` the preview stays a dead player and each hover does nothing, with no feedback after the first error. Principle: no silent failures.

4. EVPCore/FramePreview.swift:15-18 — a second hardware decoder and demuxer stay alive for the whole window life after the first hover; they are never released when the pointer leaves (the paused preview player keeps its VideoToolbox session and buffers). Resource cost grows with the number of windows ever hovered. Principle: lower resource use. Fix candidate: nil the preview some seconds after hover ends. This is a decision for the owner, not a defect.

5. EVP/PlayerWindowController.swift:128-133 — every failed decode calls `bar.showFeedback("Preview: ...")`, and `ScrubBar.hover` runs on every mouse move. A file where the screenshot fails (for example no video track, audio-only) reports a feedback message per mouse move and keeps re-decoding, with no stop after the first failure. Principle: no silent or noisy failure loops.

6. EVP/MediaKeys.swift:12 — stale comment "nil when no window is playing"; `target` now returns a paused or playing video window. EVP/MediaKeys.swift:36 — "Call whenever a window starts or stops playing, opens or closes, or the decoupling changes" omits the new trigger: the main window changing. `refresh()` is not called on `didBecomeMain`, so the published paused or playing state can describe a window that is no longer the key target. Impact is cosmetic for the keys themselves, because play, pause and toggle all map to `.playPause`, but a headset `play` command while the published state is stale toggles to the wrong state. EVP/EventTapRoute.swift:6 comment ("is playing") is also stale. Principle: no stale comments.

7. Tests/EVPTests/UnitMediaKeyTests.swift:22 — the name `testTheKeyUpFollowsTheKeyDownEvenWhenNothingPlaysAnymore` is stale after the rename to `videoOpen` (the case is now "the only video was just closed"). Also the `videoOpen: true` vs `false` rename leaves the router with no knowledge of paused; the "paused keeps the keys" rule lives only in `AppDelegate.mediaKeyWindow` and is covered only by the opt-in E2E (already in DEBT). Principle: stale parts.

8. Tests/EVPTests/E2EScreenshotTests.swift:25-26 — checks the PNG dimensions (1280x720) only, exhaust-based: a black frame at the right size passes. The defect named (zero-copy hwdec cannot be screenshotted) is caught through the "Error" feedback, so the test is still falsifiable for it; the pixel content is unchecked. Principle: mark exactly.

9. EVPCore/FramePreview.swift:6-14 — property `file` holds the JPEG path while `init(file:)` takes the video file; inside `init` the parameter `file` shadows `self.file`. It is correct today but one edit from loading the wrong URL. Principle: simplest logic / naming. Rename the property to `scratch`.

10. EVPCore/FramePreview.swift:13-14,19 — the JPEG scratch file is removed only in `deinit`; a killed app leaves `evp-preview-*.jpg` in the temp directory (about 10 KB each, once per hovered window).

No HIGH. 2 MEDIUM. Child window handling on close, retain cycles (`[weak self]` on every closure, `WakeBox` weak player), events after close (`preview = nil`, `player.onEvent = nil` before `video.shutdown()`), and deinit of the second `MpvPlayer` on the main thread are sound.
