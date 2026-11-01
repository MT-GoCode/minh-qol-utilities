#!/bin/bash
# Play a wav in QuickTime Player (hidden, output muted) and capture QuickTime's audio with the probe app.
#   play_and_capture.sh <wav> <secs> <sck|tap> [sample-rate] [paused]
set -euo pipefail
WAV="$1" SECS="$2" MODE="$3" RATE="${4:-48000}" PAUSED="${5:-}"
APP="$HOME/Applications/TranscribeEverything.app"
WAS_MUTED="$(osascript -e 'output muted of (get volume settings)')"
trap 'osascript -e "set volume output muted $WAS_MUTED"; osascript -e "tell application \"QuickTime Player\" to quit" >/dev/null 2>&1 || true' EXIT
osascript -e 'set volume output muted true'
open -g -a "QuickTime Player" "$WAV"
for _ in $(seq 20); do pgrep -x "QuickTime Player" >/dev/null && break; sleep 0.5; done
sleep 1
TARGET=$([ "$MODE" = sck ] && echo com.apple.QuickTimePlayerX || pgrep -x "QuickTime Player")
[ -n "$PAUSED" ] || osascript -e 'tell application "QuickTime Player" to play document 1'
open -W -n "$APP" --args "$MODE" "$TARGET" "$SECS" "$RATE"
cat "$HOME/.transcribe-everything/probe/$MODE.json"
