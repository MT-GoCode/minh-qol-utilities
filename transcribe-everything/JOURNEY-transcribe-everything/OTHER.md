# Deferred

- Better long-session speaker clustering. Measured: a 134–269-segment session can end with one spurious
  "Speaker N" (DECISIONS → Speakers). Centroid merging was simulated and rejected. Revisit only if real
  meetings show it.

## Deferred from the S9–S15 blueprints
- Provisional rows render like committed ones; no requirement says they should look different (`Rendered.Row.provisional` is unused by the overlay).
- A scrolled-up view shifts when its oldest lines expire (the clip origin is kept, the content moves up).
- `app.log` (the LaunchAgent's stdout and stderr) has no rotation; it holds a few lines per start.
- Every app start writes one transcript file even when nothing is attached; Delete old transcriptions clears them.

## Minh's hands-on checks (automated work cannot prove these)
Run with the app installed (`./install.sh`). One sitting takes about 15 minutes.
1. **Icon (S9).** Log out and in, or Quit then `./install.sh`: the dot goes yellow, then green. Stop turns it grey, Start yellow then green. Quit removes it and it stays gone 10 s.
2. **Menu (S10).** Attach to Apps lists real window titles, grouped by app, with a separator between apps. Clicking a row checks all that app's rows. Clicking again detaches.
3. **Captions (S11).** Play speech in an app and attach it. Captions appear over other apps and over a full-screen app. A click on empty panel area reaches the app beneath; a click on a caption line does not.
4. **Bar (S12).** Drag ⠿ moves the overlay. ⌃ shows the last minute and scrolls. The eye hides captions while the three buttons stay and the eye is crossed. Hide/Show in the menu does the same. Your typing focus in another app is never lost.
5. **Copy (S13).** Select a caption line with the mouse: captions hold still. ⌘C, paste elsewhere: the paste equals the selection. Dragging the selection does nothing. Clicking elsewhere: captions resume.
6. **Settings (S14).** Drag the Font size slider: captions resize live and it snaps to whole numbers. Set `windowSeconds` to 5 in `~/.transcribe-everything/config.json`: older captions leave sooner. Break the JSON: a red reason shows under the slider and captions keep their size. Fix it: the reason clears.
7. **Mic and AirPods (S8).** With AirPods connected and as the default input, attach Microphone and read a sentence: a `[Mic]` line appears. **Listen: the AirPods must stay normal quality, with no drop to call-mode sound.** Disconnect and reconnect them: the mic keeps working or shows a reason.
8. **Lid and sleep (S7, S8).** With an app and the mic attached: stayup on, close the lid 20 s, open. Then stayup off, close the lid 20 s so it really sleeps, open. Either captions continue or the menu shows why each source ended. Decide whether a lid-closed meeting needs to keep transcribing.
9. **Second display (S7).** With one connected, an app on the second display still captures.
10. **Zoom (S15).** A real meeting with 2+ remote speakers, attached from the menu: each voice gets its own `[Speaker N]`, and `tail -f ~/.transcribe-everything/transcripts/*.jsonl` shows the same lines.
11. **Reinstall (S15).** `./uninstall.sh` then `./install.sh`: the app returns without asking for permissions again.
