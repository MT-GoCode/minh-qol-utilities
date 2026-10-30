# evp — Ergonomic Video Player

A macOS video and audio player built on libmpv, in progress. Plays everything mpv plays, with the
controls outside the picture, per-file resume, and VSCode-style restore of every window.

## Development

```
./test                       the whole suite; output in results/<timestamp>/
./test --filter Integration  a filter on the same suite, never a separate suite
```

Requires `swift`, `ffmpeg` (test media) and `mpv` (`brew install mpv`); `./test` checks and says what is missing.

## Layout

| path | role |
| :- | :- |
| `Sources/CMpv` | system-library module over Homebrew's libmpv headers |
| `Sources/EVPCore` | everything that does not touch the UI, starting with `MpvPlayer` |
| `Tests/EVPTests` | the one test suite (`Integration*`, later `Unit*` and `E2E*`) |
| `Tools/make-fixtures` | generates the test media into `.fixtures/` |
| `Tools/evpdrive.swift` | synthetic key and media-key input plus window discovery, run via `rac exec` |
