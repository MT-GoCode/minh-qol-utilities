#!/bin/bash
# Play a wav in a throwaway Chrome instance (own temp profile, output muted) and capture that instance's
# audio with the probe app's SCK path. Chrome renders audio in a helper process, so this checks whether
# SCContentFilter(including: [app]) picks up helper-process audio.
#   chrome_capture.sh <wav> <secs>
set -euo pipefail
WAV="$1" SECS="$2"
APP="$HOME/Applications/TranscribeEverything.app"
PROFILE="$(mktemp -d /tmp/te-chrome.XXXXXX)"
WAS_MUTED="$(osascript -e 'output muted of (get volume settings)')"
cleanup() {
    pkill -f "user-data-dir=$PROFILE" || true
    osascript -e "set volume output muted $WAS_MUTED"
    rm -rf "$PROFILE"
}
trap cleanup EXIT
osascript -e 'set volume output muted true'
open -g -n -a "Google Chrome" --args --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
    --autoplay-policy=no-user-gesture-required --new-window "file://$WAV"
for _ in $(seq 30); do
    PID="$(pgrep -f "user-data-dir=$PROFILE" | while read -r p; do ps -o args= -p "$p" | grep -q -- "--type=" || echo "$p"; done | head -1)"
    [ -n "$PID" ] && break; sleep 0.5
done
sleep 3
open -W -n "$APP" --args sck "$PID" "$SECS" 16000
cat "$HOME/.transcribe-everything/probe/sck.json"
