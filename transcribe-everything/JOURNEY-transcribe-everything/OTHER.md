# Deferred

- Better long-session speaker clustering. Measured: a 134–269-segment session can end with one spurious
  "Speaker N" (DECISIONS → Speakers). Centroid merging was simulated and rejected. Revisit only if real
  meetings show it.

## Deferred from the S9–S15 blueprints
- Provisional rows render like committed ones; no requirement says they should look different (`Rendered.Row.provisional` is unused by the overlay).
- A scrolled-up view shifts when its oldest lines expire (the clip origin is kept, the content moves up).
- `app.log` (the LaunchAgent's stdout and stderr) has no rotation; it holds a few lines per start.
- Every app start writes one transcript file even when nothing is attached; Delete old transcriptions clears them.
