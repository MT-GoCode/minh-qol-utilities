# Deferred

- Better long-session speaker clustering. Measured: a 134–269-segment session can end with one spurious
  "Speaker N" (DECISIONS → Speakers). Centroid merging was simulated and rejected. Revisit only if real
  meetings show it.

## Settle at the blueprint of the named stratum (review round 8, all LOW)
- S9: Stop or Quit during the yellow phase: Stop wins when the load finishes.
- S9/S15: a crash restart comes back green with nothing attached; show a bar note or accept it in DECISIONS.

## Deferred from the S11–S13 blueprints
- Provisional rows render like committed ones; no requirement says they should look different (`Rendered.Row.provisional` is unused by the overlay).
- A scrolled-up view shifts when its oldest lines expire (the clip origin is kept, the content moves up).
- Hiding the captions while a selection exists leaves the hold on until the panel resigns key.
