# North Star — transcribe-everything

A local, always-available live transcriber for whatever audio is on this Mac. Minh's words:
REQUIREMENTS-VERBATIM.md.

## SHINY (make-or-break)
1. **Live captions of any app, or the mic, each its own stream.** "Attach to Apps" lists window names
   (refreshed at startup and every 5 s, checkmarks); the mic is its own source. Text appears while the
   audio plays.
2. **Speaker labels per lifecycle.** Within a source, distinct voices become Speaker 1, 2, ... for the
   life of the engine. Speakers do not overlap (assumption).
3. **See-through caption overlay.** No background, like TV captions. Lines `[tag] [Speaker N] text`;
   `[tag]` (first 5 chars of the window name) when > 1 source is attached, or when the displayed lines span > 1 source; `[Speaker N]` only when
   that source has > 1 speaker. Shows the past 20 s or the full sentence.
4. **Overlay bar.** Grip moves the overlay around the screen; ⌃ expands to the last minute; eye hides
   it. Text can be highlighted and copied.
5. **Offline store, single source of truth.** One JSONL file per engine start keyed by start time; the
   overlay renders from it; other tools read it. Menu item deletes old transcript files.

## Also required
- Fast and local: Parakeet Ultra on the Neural Engine via FluidAudio (Core ML).
- Menu-bar app: engine starts on launch and via Start transcription; icon yellow while starting,
  green when ready and processing; starting checks and requests permissions idempotently.
- Menu: font size as an integer within a range; Hide/Show.
- Settings configurable on the fly.
- wtalk-like setup and install scripts, no sudo, no Accessibility.
- Minimal and controllable — own code, small surface.
