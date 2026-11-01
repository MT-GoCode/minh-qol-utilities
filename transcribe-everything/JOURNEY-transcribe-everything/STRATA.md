# Strata — transcribe-everything

Requirements: REQUIREMENTS-VERBATIM.md (Minh's words), NORTH-STAR.md. Every constant below is measured or decided in
DECISIONS.md.

One SwiftPM package at `transcribe-everything/` (FluidAudio pinned `exact: "0.18.0"`): library `TECore` (engine, no GUI),
library `TEUI` (menu, overlay, permissions behind a protocol), executable `TranscribeEverything` (thin `main`), test target
`TECoreTests`.

**One test command**: `./test.sh [filter]` = `swift test -c release [--filter]` (release, like every measured number), xunit output
to `test-results/<timestamp>/`. Test classes are the categories: `Store`, `Oracle`, `Pipeline`, `Speakers`, `Live`, `Render`,
`Sources`, `App`, `Capture`, `Mic`, `Lifecycle`, `Attach`, `Overlay`, `Bar`, `Selection`, `Config`, `Install`. No test skips. Nothing
depends on rac. Everything runs in-process with an injected data root unless named below, and never touches Minh's data or cursor.

**`AppHarness`** (tests that need real permissions: `App`, `Capture`, `Mic`, parts of `Overlay`, `Attach`, `Install`): once per run, runs
`build.sh`, boots out the LaunchAgent if loaded and restores it at the end, and asserts the installed binary's hash equals the fresh
build. It fails with a clear message if the screen is locked (a locked session gets a silent mic). It launches the app via `open -W -n`
with `verify <scenario.json>` and reads a JSON report; system output is muted during capture and restored after.

**Fixtures** (`setup.sh` → `fixtures.py`, uv; into `~/Library/Caches/transcribe-everything/`, never committed and never under the data
root), LibriSpeech test-clean: `conversation` (speakers 20–22 × 4 turns, 0.8 s gaps, truth JSON + per-turn clips), `continuous` (speaker
20's clips trimmed at RMS < 0.01 / 20 ms frames, joined with 0.15 s gaps, > 40 s), `embed-heldout`, `embed-long` (speakers 23–39). `setup.sh`
builds `fluidaudiocli` from the pinned checkout and records the oracle (text + word times) for every turn and the whole of each file: FluidAudio's own
`AsrManager.transcribe` path, independent of ours.

**Core abstractions** (created early, only extended later):
- `Paths(root:)` — the data root, injected everywhere; default `~/.transcribe-everything`.
- `ConfigStore` — single owner of settings: current `Config` + change stream. Defaults = DECISIONS values (minSilence 0.5, maxSegment 12,
  speakerThreshold 0.35, speakerMinSeconds 2.0, windowSeconds 20, expandedSeconds 60, fontSize 22 in fontSizeRange 12…48). The pipeline reads it
  at segment open, render per call. In memory until S14 adds the file.
- `AudioSource` protocol — `id: SourceID`, `tag: String`, `chunks() -> AsyncThrowingStream<Chunk, Error>`, `stop()`. A finished stream means ended; a
  thrown error means failed. `Chunk` = 16 kHz mono `[Float]` + first sample index. Leaves: `FileSource` (S1; pacing by an injected `Clock`),
  `AppSource` (S7), `MicSource` (S8).
- `Line` (Codable, all fields required) — `t` (wall-clock ISO-8601 at commit), `src`, `tag`, `spk` (Int), `text`, `start`/`end` (seconds on the source's sample
  clock since the source started).
- `TranscriptStore` — one per engine start; sole owner of displayed text: committed `Line`s appended to `<root>/transcripts/<engine start ISO-8601>.jsonl`,
  provisional tails in memory only. `snapshot()` + one change notification is the only read path.
- `Transcriber` — one actor around Ultra with a priority queue (commits first, provisionals round-robin); pads < 0.3 s to 0.3 s; every decode goes through it.
- `Embedder` — one actor around WeSpeaker (S3).
- `SpeakerTracker` protocol — `assign(segment:) -> Int`. `SingleSpeaker` (always 1) in S1–S2, deleted wholesale in S3 for `CentroidTracker`.
- `Engine` — `attach(source)`, `detach(id)`, one `SourcePipeline` per source; reports each source's end or failure. Menu and `verify` use this one path.
- `render(snapshot:attached:now:expanded:config:) -> Rendered` — pure; the only place display rules live. `Rendered` holds the lines and the next time the result
  changes with no new data (the next expiry).

---

STRATUM 1: Store, config, file source, Ultra — reproduces FluidAudio exactly
description: Package skeleton; `Paths`, `ConfigStore`, `Line`, `TranscriptStore` (committed half), `AudioSource`/`Chunk`, `FileSource`, `Transcriber`; test `Support`:
  normalizer (lowercase, keep letters and apostrophes) and `wer(ref:hyp:)`. `setup.sh` + `fixtures.py` (from spike/make_fixtures.py).
  Files: Package.swift, Sources/TECore/{Paths,Config,Line,TranscriptStore,AudioSource,FileSource,Transcriber}.swift, Tests/TECoreTests/{Support,StoreTests,OracleTests}.swift,
  setup.sh, fixtures.py, test.sh.
verifiable execution: Store: write/reload round-trip; a second instance makes a new file; 8 concurrent appenders ⇒ 8 intact lines. Oracle: each conversation turn through
  `FileSource` → `Transcriber` is text-identical to the recorded oracle; per-turn WER in test-results (recorded 6/242). Mutation: FileSource drops every 10th chunk ⇒ text differs ⇒ red.
human-verifiable results: table of 12 turns: truth, our text, WER.

STRATUM 2: Segmentation — VAD pipeline to committed JSONL
description: `SourcePipeline`: streaming Silero VAD per 4096-sample chunk; open-segment buffer; commit = one decode of the closed segment → `Line`; force-cut at maxSegment at the
  lowest-VAD-probability chunk of the last 2 s; flush when the stream ends. `Engine` runs N pipelines over the shared Transcriber.
  Files: Sources/TECore/{SourcePipeline,Engine,SpeakerTracker}.swift, Tests/TECoreTests/PipelineTests.swift.
verifiable execution: conversation ⇒ lines map to the 12 turns by time (14 lines, 2 cuts, as `Bench cut` measured); per turn, joined-line WER ≤ oracle + 1 word per cut; each
  boundary within ±0.5 s of oracle word times. Continuous ⇒ every line ≤ 12 s, corpus errors ≤ whole-file decode + 1 word per cut (measured 2/159, 0 added). Conversation truncated 1 s
  before the last turn ends ⇒ that turn is committed. Mutations: no flush ⇒ truncated case loses the turn; no force-cut ⇒ one 53 s line.
human-verifiable results: `cat` of the session JSONL — the conversation line by line.

STRATUM 3: Speakers — per-lifecycle online clustering
description: `Embedder`; `CentroidTracker` per source: cosine to running-mean centroids, ≥ speakerThreshold joins the best, else a new speaker; segments < speakerMinSeconds inherit the
  previous speaker (the first segment of a source is Speaker 1) and do not update centroids. `SingleSpeaker` deleted.
  Files: Sources/TECore/{Embedder,CentroidTracker}.swift, SpeakerTracker.swift, Tests/TECoreTests/SpeakerTests.swift.
verifiable execution: Out-of-sample: conversation (speakers 20–22, never tuned on) ⇒ exactly 3 speakers, every turn consistent with truth (best permutation). Port check against the simulation
  (speakers 23–39, embeddings computed once, SplitMix64 seed 0): 300 sessions k=3, k=4 at 3 s crops ⇒ exact count ≥ 95% / 96% (simulation − 2 binomial SE), mean purity ≥ 98.2% / 98.7% (simulation −
  1 point); 1.0–1.9 s crops ⇒ every short segment carries the previous label. Long: 40 sessions over `embed-long` k=3 ⇒ final clusters ∈ {3, 4}, mean purity ≥ 96%. Mutations: threshold 0 ⇒ 1 cluster;
  threshold 1 ⇒ over-split; inherit rule removed ⇒ short-segment check red.
human-verifiable results: JSONL with `spk` 1/2/3 following the voices.

STRATUM 4: Live — provisional tail in the store
description: While a segment is open, re-decode it every chunk (skipped while that source's previous decode is in flight; latest audio wins) and set the store's provisional tail; cleared atomically
  with the commit. Transcriber priority serves commits first.
  Files: SourcePipeline.swift, TranscriptStore.swift, Transcriber.swift, Tests/TECoreTests/LiveTests.swift.
verifiable execution: Deterministic: queued provisionals + one commit ⇒ the commit is served next (mutant: FIFO ⇒ red). One real-time-paced run, 3 conversation sources started 0/1/2 s apart: per turn, first
  non-empty provisional ≤ 0.866 s after oracle onset + measured decode + round-robin wait counted from the queue; commit ≤ 1.28 s after oracle last word + its decode + embed + one in-flight decode + commits queued
  ahead (counted) × decode; queue wait itself is never added. A provisional's text equals a fresh decode of the same samples. Machine load above the measured limit (load average 26 tripled decode time)
  fails the test with that reason, not a timing error.
human-verifiable results: per-turn first-text / commit latency table in test-results.

STRATUM 5: Caption render rules — End of headless core Period
description: `render(...)`: `[tag] [Speaker N] text`; tag (first 5 chars) only when > 1 source attached; `Speaker N` only when that source has > 1 speaker (earlier lines relabel); window = lines with `t` ≥ now −
  windowSeconds (expanded: expandedSeconds), extended back within each source to the start of the sentence (earlier lines until the line before ends with `.`, `?`, `!`), never beyond expandedSeconds; ordered by `t`; each
  source's provisional tail last, marked provisional. `Rendered.nextChange` = the next expiry.
  Files: Sources/TECore/Render.swift, Tests/TECoreTests/RenderTests.swift.
verifiable execution: table tests over constructed snapshots: each visibility combination; window edges (now−20.01 s out, now−19.99 s in); a sentence split across two lines straddling the edge shows both; no punctuation
  stops at expandedSeconds; relabel on a second speaker; cross-source order; `nextChange`. Mutations: drop the > 1-source rule; drop the sentence extension ⇒ red. Whole-codebase review.
human-verifiable results: rendered captions of the S3 conversation printed by the test.

STRATUM 6: The app identity — build, sign, install, verify
description: `build.sh`: build, assemble the bundle (bundle id, LSUIElement, NSMicrophoneUsageDescription), sign (signing-ladder Developer ID, hardened runtime, audio-input entitlement), install the single copy to
  `~/Applications`. The engine holds `beginActivity(.latencyCritical)`. `verify <scenario.json>` builds the same controller as a normal launch and writes a JSON report. `AppHarness`. Spike folder deleted wholesale (Minh's commit first).
  Files: build.sh, Sources/TranscribeEverything/main.swift, Sources/TEUI/{AppController,Verify}.swift, Tests/TECoreTests/{AppHarness,AppTests}.swift.
verifiable execution: under the app identity, `FileSource` conversation with Ultra ⇒ text identical to the oracle and decode latency reported at the probe's level (12 s ≤ 2× the measured 72 ms); harness refuses a stale binary (mutant:
  skip the hash check, modified binary ⇒ red).
human-verifiable results: `codesign -dv` of the installed app: Developer ID, hardened runtime.

STRATUM 7: Per-app capture
description: `AppSource`: SCK per-app audio, 16 kHz mono; ends on `NSWorkspace.didTerminateApplicationNotification` for its pid (flush, end); `didStopWithError` (for example sleep or display change) fails the stream.
  Files: Sources/TECore/AppSource.swift, Tests/TECoreTests/CaptureTests.swift.
verifiable execution (`AppHarness`): QuickTime playing the conversation with output muted ⇒ per turn WER ≤ oracle + 1 word per cut, 3 speakers, latency within S4's bounds; pausing 10 s mid-run keeps boundaries within ±0.5 s; quitting QuickTime mid-run ⇒ the
  source ends with its last line committed. A throwaway Chrome instance (temp profile) ⇒ lines match truth (helper-process audio). Mutant: no termination observer ⇒ source never ends (silence keeps coming, as probed) ⇒ red.
human-verifiable results: session JSONL from a real capture.

STRATUM 8: Microphone source
description: `MicSource`: AVAudioEngine, built-in device selected on the input unit, no voice processing, 16 kHz mono chunks, tag `Mic`; reports the bound device; restarts on `AVAudioEngineConfigurationChange`; no built-in mic (clamshell) fails with that reason.
  Files: Sources/TECore/MicSource.swift, Tests/TECoreTests/MicTests.swift.
verifiable execution (`AppHarness`): 10 s ⇒ indices advance with wall clock (±1 chunk), samples are not digital zero (mutant zeros ⇒ red), bound device is built-in regardless of default input. QuickTime's captured RMS with the mic attached is within 1% of baseline (repeat baselines differ 0.3%).
  Mic and QuickTime together ⇒ QuickTime lines carry their tag and render shows tags. Posting the configuration-change notification ⇒ chunks resume.
human-verifiable results: required gate: Minh reads a sentence with AirPods connected: one correct `Mic` line, AirPods stay in normal mode.

STRATUM 9: Status item, auto-start, lifecycle
description: `NSStatusItem` driven by one `EngineState` enum: stopped grey, starting yellow, running green. Engine starts on launch; Start/Stop in the menu; each start makes a new store. `Permissions` protocol in TEUI (real: Microphone + Screen Recording preflight, request only what is missing).
  Missing ⇒ grey and the menu names what is missing; a fresh grant applies after relaunch. Decided edges: attaching while stopped or starting records the attach set and it applies when running; Stop ends sources and keeps checkmarks; Start restores them; double Start is a no-op. Quit.
  Files: Sources/TEUI/{MenuBar,Permissions,AppController}.swift, Tests/TECoreTests/LifecycleTests.swift.
verifiable execution: in-process with a fake `Permissions` and `FileSource`: launch ⇒ starting → running with no interaction, button image matches each state; only missing permissions requested and a granted one never re-requested (idempotent); missing ⇒ grey plus named menu item; each decided edge above, by invoking
  the real `NSMenuItem` actions; restart ⇒ new file.
human-verifiable results: menu-bar icon goes yellow then green at launch.

STRATUM 10: Attach, catalog, delete old
description: Menu: Microphone (checkmark), Attach to Apps ▸ (one row per distinct app + window title from `WindowCatalog`, refreshed at launch and every 5 s in `.common` run-loop mode so an open menu updates; clicking attaches that window's app, tag = first 5 chars of the title; all its windows show the checkmark),
  Delete old transcriptions (every session file except the current). A source that ends unchecks; a source that fails unchecks and the menu shows the reason.
  Files: Sources/TEUI/{MenuBar,WindowCatalog}.swift, TranscriptStore.swift (deleteOld), Tests/TECoreTests/{StoreTests,AttachTests}.swift.
verifiable execution: `WindowCatalog` over constructed windows dedups and groups; clicking one row checks all that app's rows, second click detaches; a `FailingSource` unchecks and shows its reason; deleteOld under an injected root keeps exactly the current file. `AppHarness`: a TextEdit window's unique title appears within 5 s + measured catalog call,
  and leaves likewise.
human-verifiable results: window-scoped screenshot of the open menu with real windows.

STRATUM 11: Overlay — see-through captions that expire
description: `Overlay` (the probed panel: non-activating key-capable NSPanel, clear, floating, all Spaces + full-screen auxiliary), fixed width, top anchored under the bar, a non-editable selectable text view in a scroll view, height up to 40% of the screen; shows `render(...)` on every store change and at `Rendered.nextChange`, so captions leave during silence. Shadowed white text at
  fontSize. Click-through except over text and bar (`ignoresMouseEvents` from the mouse location each display refresh, frozen while a button is down).
  Files: Sources/TEUI/Overlay.swift, Tests/TECoreTests/OverlayTests.swift.
verifiable execution: in-process with an injected clock: appended lines appear exactly as `render` returns; append nothing, advance 21 s ⇒ the line is gone (mutant: no expiry timer ⇒ red); location over text ⇒ not ignoring, away ⇒ ignoring, button held ⇒ unchanged. `AppHarness`: window-scoped capture ⇒ alpha 0 at blank pixels and Vision OCR reads the latest line (mutant: opaque background ⇒ red).
human-verifiable results: required gate: captions over another app, a click on empty panel area reaches the app beneath.

STRATUM 12: Overlay bar — grip, expand, hide
description: Bar above the lines: one `⠿` grip (U+283F) moves the overlay (`performDrag(with:)`, `setFrameAutosaveName`); `⌃` toggles windowSeconds / expandedSeconds; eye hides the overlay; menu Hide/Show toggles the same state (one owner).
  Files: Overlay.swift, MenuBar.swift, Tests/TECoreTests/BarTests.swift.
verifiable execution: in-process: a new panel with the same autosave name restores the frame; ⌃ action shows a line older than 20 s; eye ⇒ not visible and the menu reads Show; Show ⇒ back; a minute of lines at font 48 is all reachable in the scroll view.
human-verifiable results: required gate: Minh moves the overlay with the grip, expands, hides, shows.

STRATUM 13: Highlight and copy
description: Text is highlight-and-copy only, no drag-out: the text view accepts first mouse; a hidden main menu holds Edit ▸ Copy. While a selection exists the view holds; it catches up on deselect and when the panel resigns key (selection cleared), so captions never freeze silently.
  Files: Overlay.swift, Tests/TECoreTests/SelectionTests.swift.
verifiable execution: in-process: with a programmatic selection, Copy puts exactly that text on a private pasteboard; an append leaves the selection and text unchanged; resign key ⇒ selection cleared and the view shows the latest lines (mutant: no resign handling ⇒ stale ⇒ red); drag-out disabled on the text view.
human-verifiable results: required gate: Minh selects with the real mouse, ⌘C, pastes into TextEdit; clicks elsewhere and captions resume; his frontmost app never changes.

STRATUM 14: Config live, font size
description: `ConfigStore` loads `<root>/config.json` (defaults written on first run) and watches its directory (survives atomic-rename saves). Menu font-size control: a slider snapping to integers in fontSizeRange with the value shown, writing the file (the only owner). An invalid file keeps the previous value and the menu shows the error.
  Files: Sources/TECore/Config.swift, MenuBar.swift, Tests/TECoreTests/ConfigTests.swift.
verifiable execution: editing the file, including an atomic rename, changes minSilence for the next segment (conversation count at 0.25 taken from `Bench cut`) and windowSeconds in render; moving the slider writes the integer and the text view's font follows; out-of-range ⇒ previous value kept, error shown.
human-verifiable results: Minh drags the font slider; captions resize live.

STRATUM 15: Install — End of transcribe-everything Period
description: `install.sh` (build.sh + LaunchAgent `com.minh.transcribe-everything`, direct exec, `launchctl bootstrap gui/$UID`); `uninstall.sh` (bootout, remove app and agent, keep data unless `--purge`). No sudo. README.
  Files: install.sh, uninstall.sh, README.md, Tests/TECoreTests/InstallTests.swift.
verifiable execution: full `./test.sh` green; scripts under a temporary `HOME`: `--purge` removes only that data root, plain uninstall keeps it. Real: `uninstall.sh && install.sh` ⇒ app running from the LaunchAgent, Permissions preflight true, real transcripts kept. Whole-codebase review.
human-verifiable results: required gate: log in ⇒ green icon; attach a real Zoom meeting with at least 2 remote speakers: captions appear with correct speaker labels.
