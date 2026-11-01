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

## Keys (all rebindable in Settings, Cmd+,; defaults in `Sources/EVPCore/Keymap.swift`)

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
| ctrl+space | pause every playing video, again to resume exactly those (works while EVP is in the background) |
| F7, F8, F9 | back 10 s, play / pause, forward 10 s while a video is open, playing or paused (Settings can keep them out of EVP) |

The time `4:52` in the bar: double-click it, type a time (`4:52`, `1:04:52`, `292`, `+30`, `-30`), press Return.
Escape or clicking away cancels. The strip above the buttons scrubs on click and drag and shows the time under the pointer.

## Remembering

Each file keeps its own position, speed and volume, saved about once a second, and a kill or crash loses at most that
second. Quitting with windows open brings every one back at the next launch, where it was, paused at its position (no
sudden sound). File > Open Recent lists the last ten files with where each was left. A video left within five seconds
of its end starts over.

## Menus and buttons

The bar has buttons for the screenshot (the shown frame, at the video's own size, goes to the clipboard and nowhere
else), the subtitles and the audio track; the menu bar has the same Audio and Subtitles menus. Buttons that do not fit
a narrow window fold into the `…` menu.

Hovering the progress strip shows a thumbnail of that moment above it, with the time. A second, silent decoder of the
same file makes the thumbnails (from the keyframe nearest the pointer), started on the first hover of a window.

## Layout

| path | role |
| :- | :- |
| `Sources/CMpv` | system-library module over Homebrew's libmpv headers (found through `pkg-config`) |
| `Sources/EVPCore` | everything that does not touch the UI: `MpvPlayer`, `Action`, `Command`, `Keymap`, `KeyChord`, `Settings`, `StateStore`, `FileMemory`, `SessionRegistry`, `PauseAll`, `MediaKeys`, `TrackMenu`, `TimeFormat`, `PlayerLayout` |
| `Sources/EVP` | the app (AppKit only): window, bar, time field, scrub strip, menus, Settings, global hotkey, media keys, event tap |
| `Sources/EVPStateStress` | test-only writer that the kill -9 durability test starts and kills; `scripts/build.sh` builds only `--product EVP`, so it never reaches the app |
| `Tests/EVPTests` | the one test suite: `Unit*`, `Integration*` (real libmpv, real media), `E2E*` (the real app) |
| `Tools/make-fixtures` | generates the test media into `.fixtures/` |
| `Tools/evpdrive.swift` | test driver: key presses, window list, snapshots, accessibility reads and actions; built by `./test` |
| `scripts/` | `build.sh` (builds, assembles and signs `build/EVP.app` with the repo's `signing-ladder.sh`) and `Info.plist` |

## Development

```
./test                       the whole suite; output in results/<timestamp>-<pid>/
./test --filter Integration  a filter on the same suite, never a separate suite
EVP_E2E_FULLSCREEN=1 ./test  also run the full-screen E2E test (it takes over the display)
EVP_E2E_MEDIA=1 ./test       also run the media-key E2E test (the keys go to the whole system: no music app open)
```

`./test` builds the app, runs the unit and integration tests in parallel and then the E2E tests one at a time. The E2E
tests open real windows (in the background, `evp -g`) and drive them with screenshots, accessibility and key input, so
`./test` must start from an app holding the Accessibility and Screen Recording permissions (each E2E test fails and
says so otherwise). They need an unlocked screen and cannot run while demonlock is blocking: only the headless groups
can. Requires `swift`, `pkgconf`, `mpv`
and (tests only) `ffmpeg`, all from Homebrew; `./test` checks and says what is missing.

State lives in one JSON file, `~/Library/Application Support/EVP/state.json` (`EVP_HOME` overrides the folder; the tests use a scratch one): per-file
position, speed and volume, the open windows, the recents and the settings. It is versioned, written atomically (a kill
at any instant leaves a complete file; a power cut is not covered, there is no fsync) and a corrupt or newer file is refused, never overwritten.
