#!/bin/bash
# Echo-cancellation probe with advanced ducking: waits for HID idle >= 60 s (plays audio through the
# speakers), records the mic with voice processing + advanced ducking while a conversation turn plays at
# 50% volume, then transcribes the mic capture. Expected: empty transcript (echo cancelled).
set -euo pipefail
S="$(cd "$(dirname "$0")" && pwd)"
TURN="$HOME/general-purpose/conversation-contexts/transcribe-everything/scratch/turn02.wav"
O="$HOME/.transcribe-everything/probe"
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
echo "waiting for HID idle >= 60 s"; until [ "$(idle)" -ge 60 ]; do sleep 15; done; echo "idle; running"
VOL=$(osascript -e 'output volume of (get volume settings)'); MUTED=$(osascript -e 'output muted of (get volume settings)')
trap 'osascript -e "set volume output volume $VOL" -e "set volume output muted $MUTED"' EXIT
osascript -e 'set volume output muted false' -e 'set volume output volume 50'
open -n "$HOME/Applications/TranscribeEverything.app" --args mic-vpa 13
sleep 1.5; afplay "$TURN"; sleep 12
cat "$O/mic-vpa.json"
"$S/.build/release/Bench" latency "$O/mic-vpa.wav" /tmp/echo-lat.json | grep "12.0s"
