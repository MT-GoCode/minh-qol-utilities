# Review 7 findings (6cc027f..699409d, evp/)

Round 5 findings:
1. Bubble left on screen when the bar hides or full screen toggles: FIXED for `toggleBar` and `fullscreen` through `perform` (`scrubHovered(nil)` clears `hoverTop`, so an in-flight decode is dropped by the `thumbnailReady` guard). Residual: see LOW 1.
2. Preview test could not catch concurrent seeks: FIXED. `testARequestDuringADecodeReplacesTheWaitingOne` issues 2, 5, 15 synchronously after load; the `decoding == nil` mutant seeks at once for each, so the delivered list cannot equal [2, 15] reliably.

## LOW

1. EVP/PlayerWindowController.swift:149-156 — only the `perform` path clears the bubble. Full screen from the green traffic-light button or ctrl-cmd-F, minimize, or a window resize go through AppKit, not `performInterface`, so the strip moves under the pointer with no guaranteed `mouseExited`; the thumbnail window can stay. Principle: single owner for mutable state / robustness. Fix: hide in `windowWillEnterFullScreen`, `windowWillExitFullScreen`, `windowDidMiniaturize`.

2. EVP/AppDelegate.swift:120-122 — `mediaKeyWindow` prefers a paused main window over a playing background one. Before, a playing window always won. Failure: video A (main) paused, video B playing in the background; F8 starts A and B keeps playing instead of pausing B. Also, with the app inactive, `isMainWindow` may be false for all and `players.last` is chosen regardless of which one plays. Principle: robustness (user edge case). Fix: main if playing, else any playing, else main, else last.

3. EVP/MediaKeys.swift:36 and EVP/AppDelegate.swift:111 — NOT FIXED from round 5 (LOW 6): `refresh()` runs only on play-state changes, opens, closes and settings, not when the main window changes. The published paused/playing state can describe a window that is no longer the target; since `playCommand` and `pauseCommand` both toggle, a headset `play` while the state is stale flips the wrong way. The comment on line 36 omits this trigger. Principle: single source of truth.

4. Round 5 LOW 3, 4, 5, 9, 10 (FramePreview `decoding` never clears on a missing `playbackRestart`; idle second decoder; error feedback per mouse move on failure; `file` property shadowed by the `init(file:)` parameter; scratch JPEG left after a kill) are unchanged in FramePreview.swift and PlayerWindowController.swift:131-133. Not repeated in detail.

No HIGH. No MEDIUM.
