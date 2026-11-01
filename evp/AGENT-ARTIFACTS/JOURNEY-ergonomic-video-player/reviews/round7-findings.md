# Round 7 review of 951cf17 (read only)

## Verdict on the fix
The fix is correct for the failing case. Every enqueued `FILE_LOADED` is followed by the load's own `PLAYBACK_RESTART`. mpv emits that restart when the first frame is ready, and it does so while paused with no start option. Gating readiness on the first restart means any seek is sent after that restart is consumed. The restart cannot answer the seek.
`FramePreview.swift` no longer names `fileLoaded`. The remaining uses are legitimate (`FileMemory.swift:37`, `PlayerWindowController.swift:220`, tests).

Not proven by the code: one seek yields exactly one restart. Only one seek is ever in flight (`decoding != nil` blocks the next). 15/15 passes is empirical evidence, not a guarantee.

## Findings

- MEDIUM `FramePreview.swift:49` (Mark-then-route, No fallbacks, Robustness). If a seek ever yields zero restarts (for example a seek that mpv drops or coalesces), `decoding` stays set forever. Every later `show()` silently does nothing, with no error and no timeout. The failure looks like a hang. Today's tests do not provoke it, and mpv normally emits a restart per seek. The risk is that the single-restart assumption is unchecked at runtime. Fix: mpv's `seek` command completes asynchronously. Use `mpv_command_async` with a reply, or watch the `seeking` / `core-idle` properties, so the answer is marked rather than inferred. Or defer this explicitly to OTHER.md. I rate it MEDIUM because a stuck preview is invisible to the user.

- MEDIUM `FramePreview.swift:25,45` (No fallbacks, Robustness). If the file fails to load, `.loadFailed` calls `onError` once. `loaded` stays false, and later `show()` calls are dropped silently. The caller got one error, so this is partly handled, but a hover after the error looks identical to "still loading". Unlike a restart, there is no terminal state. Fix: a `failed` state that re-reports or rejects `show()`. Alternatively, accept and document that the owner must discard a preview after `onError`.

- LOW `MpvPlayer.swift:34` (No stale parts). The doc `Playback (re)started: a seek has landed.` is now incomplete. The event also marks the load's first frame, and FramePreview now relies on that. State both.

- LOW `FramePreview.swift:7,40` (Simplest logic, naming). `loaded` now means "first restart consumed", not "file loaded". Rename it to `ready`. This matches the new comment and removes the clash with `Event.fileLoaded`.

- LOW `IntegrationPreviewTests.swift:12,36` (Stale comments). "before the file has loaded" and "Loaded:" now mean "before the first restart". Reword them.

- LOW `IntegrationPreviewTests.swift:47-59` (Test design). The regression test relies on timing and the fixture. It reproduces the bug when the load's restart arrives after the seek, which makes it a real regression test. It does not cover load failure (a missing or corrupt file), and it does not cover the zero-restart case.

## Wrong-restart cases still possible
- Two restarts per seek, or a late second restart from the load (for example a `vf` or track reconfigure): the second `!loaded` arm is already past, so the extra restart would be taken as the answer to the next seek. I found no evidence this happens (15/15), so it is not a finding.
- No other path answers a thumbnail with the wrong restart in the code read.

VERDICT: FINDINGS
