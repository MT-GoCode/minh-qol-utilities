#!/bin/bash
# Round-4 probes needing no person: true VAD boundaries, force-cut accuracy, Ultra in the signed bundle (open and
# LaunchAgent direct exec), and what SCK does when the captured app quits. Output muted; no mouse.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; D="$HOME/general-purpose/conversation-contexts/transcribe-everything"; O="$HOME/.transcribe-everything/probe"
APP="$HOME/Applications/TranscribeEverything.app"; B="$S/.build/release/Bench"
swift build -c release --package-path "$S" 2>&1 | grep -E "error:|Build complete"
"$S/probe.sh" status 2>/dev/null
echo "== vad"; "$B" vad "$D/fixtures/conversation.wav" 2>&1 | grep "minSilence 0.5"
for f in conversation continuous; do echo "== cut $f"; "$B" cut "$D/fixtures/$f.wav" "$D/cut-$f.json" 2>&1 | grep -E "^ *[0-9]+\.[0-9]+ |^WHOLE|rror"; done
echo "== decode via open"; rm -f "$O/decode.json"; open -W -n "$APP" --args decode "$D/fixtures/conversation.wav"; cat "$O/decode.json"
echo "== decode via LaunchAgent"; L="$HOME/Library/LaunchAgents/com.minh.te-probe.plist"; rm -f "$O/decode.json"
cat > "$L" <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.minh.te-probe</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/TranscribeEverything</string><string>decode</string><string>$D/fixtures/conversation.wav</string></array><key>RunAtLoad</key><true/></dict></plist>
EOF
launchctl bootstrap gui/$UID "$L"
for _ in $(seq 120); do [ -f "$O/decode.json" ] && break; sleep 0.5; done; cat "$O/decode.json"
launchctl bootout gui/$UID/com.minh.te-probe 2>/dev/null; rm -f "$L"
echo "== SCK when the captured app quits"; MUTED="$(osascript -e 'output muted of (get volume settings)')"; osascript -e 'set volume output muted true'
open -g -a "QuickTime Player" "$D/fixtures/conversation.wav"; sleep 3; osascript -e 'tell application "QuickTime Player" to play document 1'
open -n "$APP" --args sck com.apple.QuickTimePlayerX 12 16000; sleep 5; osascript -e 'tell application "QuickTime Player" to quit'
sleep 9; osascript -e "set volume output muted $MUTED"; cat "$O/sck.json"
