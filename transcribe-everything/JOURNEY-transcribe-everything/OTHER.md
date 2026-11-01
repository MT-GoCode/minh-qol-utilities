# Deferred

- Better long-session speaker clustering. Measured: a 134–269-segment session can end with one spurious
  "Speaker N" (DECISIONS → Speakers). Centroid merging was simulated and rejected. Revisit only if real
  meetings show it.

## Settle at the blueprint of the named stratum (review round 8, all LOW)
- S1: how `setup.sh` fetches models with no `fluidaudiocli` binary. `build.sh` may need its own `--scratch-path` to avoid `.build/.lock` contention when run from `swift test`. The `Sources` test category has no stratum: drop it or assign it.
- S3: replace "a line never holds two speakers' labels" (cannot fail) with "a mid-segment speaker change produces two lines".
- S4: add 14,000 VAD chunks to the soak; VAD is the one model called during silence.
- S6: `AppHarness` mutes output and launches apps; add a warning or idle wait so a run cannot mute Minh mid-call.
- S8: assert a restart count for the configuration-change test; posting the notification alone does not stop the engine.
- S9: Stop or Quit during the yellow phase: Stop wins when the load finishes.
- S9/S15: a crash restart comes back green with nothing attached; show a bar note or accept it in DECISIONS.
- S11: `becomesKeyOnlyIfNeeded` is new, not probed; covered by the S12 and S13 gates.
- S13: gate also tries dragging selected text, which must do nothing.
