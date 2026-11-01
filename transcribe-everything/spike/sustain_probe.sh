#!/bin/bash
S="$(cd "$(dirname "$0")" && pwd)"; D="$HOME/general-purpose/conversation-contexts/transcribe-everything"; cd "$S"; B=.build/release/Bench
run() { echo "== $1"; dur=$(awk '{e=$4+$5; if(e>m)m=e} END{print int(m)+1}' "$3"); [ -n "${4:-}" ] && dur=$4
  "$B" words "$2" "$dur" /tmp/wd.json 2>&1 | grep -E "rror"; "$B" windows "$2" "$dur" 2.0 0.5 /tmp/wn.json 2>&1 | grep -E "rror"; uv run -q analyze_sustain.py "$3" /tmp/wd.json /tmp/wn.json; }
run "clean conversation" "$D/fixtures/conversation.wav" "$D/data/ami/conversation.rttm"
run "AMI 15 min" "$D/data/ami/ES2004a.wav" "$D/data/ami/ES2004a.rttm" 900
for k in 2 3 4 6 9; do run "vox$k" "$D/data/vox/vox$k.wav" "$D/data/vox/vox$k.rttm"; done
