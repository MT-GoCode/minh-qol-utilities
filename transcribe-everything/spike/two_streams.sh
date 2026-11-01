#!/bin/bash
# Two apps captured at once in one process, each playing different speech; second run flips the default output device mid-capture. Muted.
S="$(cd "$(dirname "$0")" && pwd)"; D="$HOME/general-purpose/conversation-contexts/transcribe-everything"; O="$HOME/.transcribe-everything/probe"; APP="$HOME/Applications/TranscribeEverything.app"
cd "$S"; swift build -c release 2>&1 | grep -E "error:|Build complete"; ./probe.sh status 2>/dev/null
MUTED="$(osascript -e 'output muted of (get volume settings)')"; PROFILE="$(mktemp -d /tmp/te-chrome.XXXXXX)"
trap 'pkill -f "user-data-dir=$PROFILE"; osascript -e "tell application \"QuickTime Player\" to quit" 2>/dev/null; osascript -e "set volume output muted $MUTED"; rm -rf "$PROFILE"' EXIT
osascript -e 'set volume output muted true'
for mode in plain flip; do
    echo "== $mode"
    open -g -a "QuickTime Player" "$D/fixtures/conversation.wav"; sleep 3
    open -g -n -a "Google Chrome" --args --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check --autoplay-policy=no-user-gesture-required --new-window "file://$D/fixtures/continuous.wav"; sleep 4
    PID="$(pgrep -f "user-data-dir=$PROFILE" | while read -r p; do ps -o args= -p "$p" | grep -q -- "--type=" || echo "$p"; done | head -1)"
    osascript -e 'tell application "QuickTime Player" to play document 1'
    open -W -n "$APP" --args sck2 com.apple.QuickTimePlayerX "$PID" 14 $mode
    grep -E 'flipped_to|frames|peak|stop_error|max_buffer' "$O/sck2.json"
    for t in a b; do printf "$t: "; .build/release/Bench latency "$O/sck2-$t.wav" /tmp/s2.json 2>&1 | grep -E "12.0s|rror" | cut -c30-260; done
    pkill -f "user-data-dir=$PROFILE"; osascript -e 'tell application "QuickTime Player" to quit' 2>/dev/null; sleep 2
done
echo "== mic gap"; rm -f "$O/mic.json"; open -W -n "$APP" --args mic 15; grep -E 'device|peak|max_buffer' "$O/mic.json"
