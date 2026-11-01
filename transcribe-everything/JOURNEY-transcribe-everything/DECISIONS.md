# Decisions

Minh's own words are in REQUIREMENTS-VERBATIM.md. This file records what he decided and what the
feasibility spike measured (M4 Max, macOS 27, FluidAudio 0.18.0, LibriSpeech test-clean fixtures).
Spike code: `spike/` (Probe = TCC-holding app probes, Bench = model benches, *.py = fixtures/analysis).

## Minh's decisions
- Build our own app (minimal, controllable) at `~/code/minh-qol-utilities/transcribe-everything`,
  structured like wtalk (setup + install scripts). Host: mac-work-2.
- No sudo, no demonlock protection: install to `~/Applications` + `~/Library/LaunchAgents`.
- No Accessibility permission.
- Menu-bar app. The engine starts on launch, and Start/Stop transcription in the menu.
- Icon yellow while the engine starts, green when ready and processing.
- Starting the engine checks and requests permissions idempotently.
- Window catalog at startup and every 5 s; "Attach to Apps" hover submenu lists window names; click ⇒ checkmark.
- Mic is its own stream (an abstract "app").
- "Delete old transcriptions" menu item; one transcript file per startup keyed by startup time.
- Overlay: see-through captions, no background. Lines `[first 5 chars of window] [Speaker N] text`;
  `[tag]` hidden when only one source is attached; `[Speaker N]` hidden unless that source has > 1 speaker.
  Shows the past 20 s or the full sentence. Renders from the offline store (single source of truth).
- Overlay bar above the lines: **grip (⠿) moves the overlay around the screen**; **⌃ expands to the last
  minute**; **eye icon hides** the overlay. Menu also has Hide/Show (same state).
- **Transcript text is highlight-and-copy only. No drag-out of text.**
- **Font size: a menu control that sets an integer within a range**, applied live.
- Settings configurable on the fly.
- Speakers assumed non-overlapping; labels are per engine lifecycle.
- wtalk stays on parakeet-tdt-0.6b-v2 + MLX (not upgraded).
- No user-facing CLI. The one exception is the app's `verify <scenario.json>` subcommand: capture tests need the installed bundle's permissions, and a second copy breaks them. It builds the same controller as a normal launch.

## Model and runtime
- **Ultra is Core ML only** (no MLX port exists). FluidAudio `AsrModelVersion.ultra` runs it on the ANE.
- **Decode latency** (warm, median of 8): 0.5 s → 42 ms, 2 s → 47 ms, 4 s → 50 ms, 8 s → 62 ms,
  12 s → 73 ms. First load + ANE compile 11.3 s. Process peak RSS 677 MB.
- **FluidAudio rejects audio < 0.3 s** (`ASRConstants.minimumAudioDurationSeconds`); the pipeline pads
  shorter segments with silence to 0.3 s.
- `AsrManager` already splits audio > 15 s (`ChunkProcessor`), so segment length is not a correctness limit.
- **Ultra in the signed, hardened bundle** under `open` and under a LaunchAgent (direct exec, ppid 1): 12 s decode 69–72 ms, 2 s 46 ms, cached load 0.11 s, same text as Bench. The engine holds `ProcessInfo.beginActivity(.latencyCritical)` while running so a windowless agent is not throttled.
- **Oracle WER** (each of the 12 conversation turns decoded alone with `fluidaudiocli`, normalizer =
  lowercase, keep letters/apostrophes): 6 errors / 242 words = 2.48%, all spelling variants
  (misses/mrs, skilful, favourite, Cervadac). ⇒ Tests compare our Transcriber's text to the
  `fluidaudiocli` reference transcript exactly, and use per-turn oracle WER as the baseline.

## Segmentation (FluidAudio streaming Silero VAD, 4096-sample = 256 ms chunks)
- **minSilence 0.5 s.** On the conversation fixture: 0.5 ⇒ exactly the 12 truth turns; 0.25 ⇒ 16 segments
  (splits sentences at internal pauses); 0.75 ⇒ 11 ends, the last segment never closes.
- **End-of-stream flush** is required: a stream ending mid-speech (`continuous`) leaves its segment open.
- **End detection lag**: the end fires `ceil(minSilence/chunk) + 2` = 4 chunks (1.024 s) after the VAD's last speech chunk (VadManager+Streaming.swift). Measured from the oracle's last word end: 0.41–1.09 s (the VAD's speech can outlast the last word by up to 1 chunk) ⇒ bound 1.28 s.
- VAD boundaries vs oracle word times (80 ms frames), `Bench vad` by sampleIndex: starts −0.31…+0.23 s, ends −0.26…+0.42 s ⇒ tests allow ±0.5 s (max 0.42 + one word frame).
- Lines map to truth turns by time, and each turn's joined lines are compared, because a line is a segment, not a turn.
- **Continuous speech never closes a segment**: the 40 s `continuous` fixture (clips trimmed at
  RMS < 0.01 in 20 ms frames, joined with 0.15 s gaps) ⇒ one start event, no end. ⇒ **Force-cut at
  12 s** (keeps caption lines short and every re-decode inside one model window), cut at the lowest-VAD-probability chunk of the last 2 s. **Measured (`Bench cut`, no accuracy cost):** conversation = 14 lines (2 cuts), 6/242 errors, identical to decoding it whole; continuous = 5 lines (4 cuts, longest 11.3 s), 2/159, identical. Tests allow 1 word per cut.
- **First text** (`Bench live`, VAD + decode on the real stream grid): first non-empty text 0.28–0.59 s after
  the oracle's first word onset. Decoding each turn's growing prefix from its clip start gives ≤ 0.61 s; the
  stream grid can add up to one chunk ⇒ worst case 0.866 s. Early text is unstable ("They're not" → "The
  modest"); the commit decode corrects it.
- **Live cadence**: re-decode the open segment every chunk (256 ms). A decode is ≤ 75 ms when the machine is
  otherwise idle, so 3 simultaneously speaking sources fit in one chunk and 6 saturate the Transcriber. Latency
  depends on load: 12 s decode 73 ms idle, 206 ms median at load average 26.
- **Soak, one hour of speech's worth of live work** (`Bench soak`: 14,000 growing-prefix decodes, 7,169 embeddings, 19 min): no leak and no slowdown. Footprint 318 MB at 1,000 decodes, 332 MB by 4,000, 336 MB at 14,000; decode median 50–58 ms throughout, occasional max about 300–340 ms (so tests use measured durations, never the median); embedding about 32 ms.
- **Latency bounds used by tests**: first provisional ≤ 0.866 s after oracle onset + that decode's measured
  duration; commit ≤ 1.28 s (4 chunks + 1 chunk VAD tail) after oracle last word end + its measured decode +
  embed + one in-flight decode (≤ measured max) + commits queued ahead (counted) × measured decode. Queue wait
  itself is never added, so starved commits go red.

## Speakers
- **One label per segment fails on real meetings** (AMI ES2004a, 15 min, 4 people, human labels): 74.8% of speech time sat in segments holding more than one speaker; best possible 77.6%. People reply inside minSilence; 0.25 s barely helps (71.5%). Clean LibriSpeech never showed this.
- **Design: label words, not segments.** While speech is open, embed sliding 2 s windows at a 0.5 s hop (WeSpeaker `DiarizerManager.extractSpeakerEmbedding`, 256-d, 31 ms median; CAM++ rejected, worse and 83 ms). Each Ultra word takes the label of its nearest window. A committed segment becomes one `Line` per run of same-speaker words. Segments with no window inherit the previous speaker (first ever: Speaker 1); windows keep being emitted through the silent tail until the end event, as measured. The provisional tail takes the current label.
- **Tracker**: per-source running-mean centroids, cosine, threshold 0.35. A new speaker needs **4 consecutive windows below threshold** (about 2 s of sustained new voice); until then they keep the previous label, so a laugh or noise cannot spawn a speaker, and a new speaker's first words stay on the previous label. The tracker lives for the engine start, keyed by `SourceID`, so detach/re-attach keeps labels. FluidAudio's `SpeakerManager` has no sustained rule and works per segment, so it is not used.
- **Measured** (`spike/analyze_sustain.py`, per word, one-to-one Hungarian mapping, so a spurious speaker costs its words; speakers found/true, accuracy): clean conversation 3/3 94.6%; AMI 5/4 96.7%; VoxConverse 2-speaker 4/2 92.5%, 3-speaker 3/3 99.2%, 4-speaker 4/4 98.5%, 6-speaker 6/6 93.6%, 9-speaker 9/9 90.8%. Without the sustained rule: AMI 10/4, 2-speaker 16/2.
- **LS-EEND rejected** despite shipping in FluidAudio: it looked best only on AMI, its `.ami` training corpus (4/4, 90.8%). On VoxConverse every variant fell apart: 4-speaker 60.8–68.1%, 9-speaker 35.8–58.3%, counts wrong. `.dihard3` degraded past its documented 1 h (last repeat of a 90 min run 45.6%, footprint 400 MB).
- Known limit: some recordings can show extra speakers (2-speaker clip above: 4). Merging centroids was simulated and rejected (wrong merges, purity 89–93%).

## Capture and permissions
- **Per-app audio = ScreenCaptureKit** (`SCContentFilter(display:including:[app])`, `capturesAudio`,
  `sampleRate = 16000`, `channelCount = 1` — 16 kHz mono delivered natively, no resampler). Captures with
  system output muted. Ultra transcript of a captured QuickTime playback matched ground truth exactly.
- **SCK delivers continuous zero buffers while the app is silent** (8.04 s of frames in an 8 s paused
  capture) ⇒ a source's sample clock tracks wall clock.
- **Window catalog = `SCShareableContent.windows`** (title, app name, bundle id, pid; layer 0, non-empty
  title), same Screen Recording grant.
- **Attach is per app**: clicking a window attaches its app (bundle id + pid); all of that app's windows
  show the checkmark; tag = first 5 chars of the clicked window's title; mic tag = `Mic`. SCK reports nothing when the captured app quits: it kept delivering silence with no `didStopWithError` (12.5 s of frames, app quit at 5 s). So `AppSource` ends on `NSWorkspace.didTerminateApplicationNotification` for that pid: flush, end, uncheck.
- **Chrome audio is captured through the main app**: an SCK filter on `com.google.Chrome` (throwaway instance by
  pid) picked up its helper processes; Ultra's transcript of the capture matched the truth exactly. Zoom uses the
  same mechanism, is not probed (needs a meeting), and is Minh's human check in the app stratum.
- **Mic = AVAudioEngine, built-in mic, no voice processing (Minh approved).** Minh's own voice through it: Ultra returned "The quick captions. Hello, hello." (his read, 14 s, peak 0.12). Selecting
  the built-in device on the plain path works (peak 0.15, device "MacBook Pro Microphone" unlocked). Voice
  processing rejected: it lowers other apps' audio about 8 dB (RMS 0.069 → 0.027, advanced ducking no better),
  about 29 dB with AirPods; it follows the default input (flipping AirPods to hands-free), and selecting a device
  under it binds the speakers and records silence. Cost accepted: without headphones, an attached mic also
  transcribes speaker audio (probe: exact transcript at 50% volume). A locked session gets a silent mic.
- **Engine start can fail** (model download, corrupt cache): grey icon, the reason in the menu, Start retries. `setup.sh` fetches the Ultra, VAD and WeSpeaker models so first launch has no surprise download.
- A permission granted while the app runs is not assumed to apply until relaunch (a request left preflight false in that process; later processes saw true). The menu names what is missing and macOS's own Quit & Reopen, or a relaunch, picks it up.
- **Two apps at once work in one process** (`sck2`: QuickTime and a throwaway Chrome playing different speech, two `SCStream`s): each capture held only its own speech by Ultra transcript, 14.8 s of frames each, largest gap 65 ms. Flipping the default output device mid-capture changed nothing: no error, largest gap 67 ms, transcripts continued.
- **Stall = failure**: SCK delivers buffers continuously, including silence (largest gap 65 ms over 15 s under load), so a gap over 1 s (15× measured) means capture has stopped, whatever the cause (sleep, display change). `AppSource` fails the stream with that reason, so the source unchecks visibly instead of looking like silence. `MicSource` has the same guard (largest normal gap 107 ms). The failure reason shows in the overlay bar as well as the menu, because a menu nobody has open is not visible mid-meeting. A failed stream commits its open segment and clears its tail, like an ended one.
- **Permissions = Microphone + Screen Recording.** App: `~/Applications/TranscribeEverything.app`,
  bundle id `com.minh.transcribe-everything`, signed `Developer ID Application: Minh Trinh (BULCQM9J2V)`,
  hardened runtime + `com.apple.security.device.audio-input`, `NSMicrophoneUsageDescription`. Grants
  persist across delete-and-recreate + re-sign (every build). **Exactly one app copy**: two copies with
  the same bundle id broke TCC matching.
- **LaunchAgent with direct exec** of `Contents/MacOS/TranscribeEverything` keeps the grants (verified).
- **No dependency on rac** (Minh): nothing in this repo calls it. App logic, menu and overlay are tested
  in-process (real objects, `NSEvent`s sent to the panel, `NSMenuItem` actions), which needs no permissions
  and never touches Minh's cursor. Real cursor behaviour is a human check.

## Store and display
- `TranscriptStore` owns all displayed text, one instance per engine start (so speaker labels and file agree):
  committed lines in `~/.transcribe-everything/transcripts/<engine start ISO-8601>.jsonl`, provisional tails in memory only.
  `snapshot()` + one change notification is the only read path.
- Display window is on wall-clock `t`; lines are ordered by `t` across sources. A line is a VAD segment,
  not a sentence, so the window extends back within a source to the start of the sentence: earlier
  lines of that source are included until the line before them ends with `.`, `?` or `!` (Ultra
  punctuates).
- **Overlay panel** (probed): borderless `.nonactivatingPanel` NSPanel subclass with `canBecomeKey = true`,
  clear background, `.canJoinAllSpaces + .fullScreenAuxiliary`, non-editable selectable NSTextView:
  shows only shadowed text over content; selectAll + copy puts exactly the rendered text on the
  pasteboard; becoming key left the frontmost app unchanged. Vision OCR reads a window-scoped capture.
- **Real-mouse selection and copy work** (Minh, by hand, two runs on the probe panel with `acceptsFirstMouse` and a
  hidden main menu holding Edit ▸ Copy): a drag selected text, ⌘C put it on the clipboard (`ig it out of the `),
  status-item menu clicks fired (3 of 3), the frontmost app stayed Paseo and the probe app stayed inactive.
- **Grip and click-through work with the real mouse** (Minh, by hand): `performDrag(with:)` from a first-mouse grip view moved the panel; polling the mouse location each display refresh and toggling `ignoresMouseEvents` (frozen while a button is down) passed clicks on empty panel area to the app beneath while text stayed selectable.
- The grip glyph is one `⠿` (U+283F).
- **Overlay scrolling**: fixed width, height up to 40% of the screen, follows the newest line unless Minh has scrolled up, resumes at the bottom. Updates hold from mouse-down so a selection anchor cannot move. A restored frame is clamped to a visible screen.
- Overlay position is AppKit window state, not a setting: `NSWindow.setFrameAutosaveName`.
- The grey "stopped" icon is derived: Stop needs a state distinct from yellow and green.
- Start requests only missing permissions; while any is missing the icon stays grey and the menu names it; Start
  again retries. Nothing assumes a running process sees a fresh grant.
- Menu and overlay are tested in-process (see the rac line); no scripted clicks.
- Font size default 22 pt (rendered legibly in the panel probe); range default 12…48 (Minh asked for an
  integer within a range without bounds; 12 is macOS small text, 48 is large caption text); both editable
  in config.
- Settings live in `~/.transcribe-everything/config.json` (Codable defaults). The menu's font-size control
  writes that file; the file is the single owner of every setting.

## Review bar (Minh)
- HIGH and MEDIUM mean a real functionality or robustness defect, or a requirement gap. Polish is LOW and never blocks. No cap on rounds.
- Attach per app is accepted, though Minh said "window": clicking a Chrome window attaches all of Chrome.
