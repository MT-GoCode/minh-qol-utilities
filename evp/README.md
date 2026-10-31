# evp — Ergonomic Video Player

A macOS video and audio player on libmpv (the engine of mpv and IINA), so it plays mkv, mp4, mov, webm, avi, flac,
mp3 and the rest of what ffmpeg reads. The controls sit in a bar below the picture and never over it; resizing
fits the video with black bars; the keys are the ones from YouTube.

```
evp ~/Movies/lecture.mkv                 open a file (one window each)
evp --time 4:52 lecture.mkv              open it at 4:52
evp -g lecture.mkv                       open it without taking focus
```

No sudo, no daemon, no macOS permission prompt for playing. `./install.sh` builds `EVP.app` into `~/Applications` and
puts `evp` in `~/.local/bin`; `./uninstall.sh` removes both (`--purge` also removes the saved state).

## Install

It never installs anything itself. `./install.sh` first checks Swift, Homebrew, `pkgconf` and `mpv`, prints a pass or
fail mark for each, and for anything missing prints the exact command (for example `brew install mpv pkgconf`) and
stops. A `brew install` can upgrade unrelated packages, so you run it yourself.

## Keys (all rebindable once the Settings window exists; defaults in `Sources/EVPCore/Keymap.swift`)

| key | does |
| :- | :- |
| space | play / pause |
| left, right | back, forward 5 s (held keys repeat) |
| J, L | back, forward 10 s |
| d, s | speed up, down by 0.1x |
| up, down | volume up, down by 5 |
| 0 to 9 | jump to 0% to 90% of the video |
| `,` `.` | one frame back, forward |
| m, f, tab | mute, full screen, hide the bar |
| ctrl+space | pause everything (global; not wired yet) |

The time `4:52` in the bar: double-click it, type a time (`4:52`, `1:04:52`, `292`, `+30`, `-30`), press Return.
Escape or clicking away cancels. The strip above the buttons scrubs on click and drag and shows the time under the pointer.

## What is built, what is not wired yet

Playing, the control bar, the keyboard, the time field, scrubbing and the installer work and are tested against the
real app. The logic for per-file resume (position, speed and volume), restoring every window at launch, the Open Recent
menu, the audio and subtitle menus, the screenshot, settings validation, the global pause and the media-key rules is
written and tested headless against real media (`Sources/EVPCore`), and its wiring into the app is the next step.

## Layout

| path | role |
| :- | :- |
| `Sources/CMpv` | system-library module over Homebrew's libmpv headers (found through `pkg-config`) |
| `Sources/EVPCore` | everything that does not touch the UI: `MpvPlayer`, `Action`, `Command`, `Keymap`, `KeyChord`, `Settings`, `StateStore`, `FileMemory`, `SessionRegistry`, `PauseAll`, `MediaKeys`, `TrackMenu`, `TimeFormat`, `PlayerLayout` |
| `Sources/EVP` | the app (AppKit only): window, bar, time field, scrub strip |
| `Sources/EVPStateStress` | test-only writer that the kill -9 durability test starts and kills; not part of the app build |
| `Tests/EVPTests` | the one test suite: `Unit*`, `Integration*` (real libmpv, real media), `E2E*` (the real app) |
| `Tools/make-fixtures` | generates the test media into `.fixtures/` |
| `Tools/evpdrive.swift` | test driver: key presses, window list, snapshots, accessibility reads and actions; built by `./test` |
| `scripts/` | `build.sh` (builds, assembles and signs `build/EVP.app` with the repo's `signing-ladder.sh`) and `Info.plist` |

## Development

```
./test                       the whole suite; output in results/<timestamp>-<pid>/
./test --filter Integration  a filter on the same suite, never a separate suite
EVP_E2E_FULLSCREEN=1 ./test  also run the full-screen E2E test (it takes over the display)
EVP_RAC=<path> ./test        use another copy of the rac script (E2E tests run the driver through `rac exec`)
```

`./test` builds the app, runs the unit and integration tests in parallel and then the E2E tests one at a time. The E2E
tests open real windows (in the background, `evp -g`) and need `rac exec` for screenshots, accessibility and key input,
so they cannot run while demonlock is blocking: only the headless groups can. Requires `swift`, `pkgconf`, `mpv`
and (tests only) `ffmpeg`, all from Homebrew; `./test` checks and says what is missing.

State lives in one JSON file, `~/Library/Application Support/EVP/state.json` (`EVP_HOME` overrides the folder): per-file
position, speed and volume, the open windows, the recents and the settings. It is versioned, written atomically (a kill
at any instant leaves a complete file) and a corrupt or newer file is refused, never overwritten.
