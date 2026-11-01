#!/bin/bash
S="$(cd "$(dirname "$0")" && pwd)"; D="$HOME/general-purpose/conversation-contexts/transcribe-everything"; A="$D/data/ami"
cd "$S"; swift build -c release --product Bench 2>&1 | grep -E "error:|Build complete"; B=.build/release/Bench
[ -s "$A/IS1009a.wav" ] || curl -sSfL -o "$A/IS1009a.wav" https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/IS1009a/audio/IS1009a.Mix-Headset.wav
for v in dihard3 callhome dihard2 ami; do
    for m in ES2004a IS1009a; do echo "== $v $m"; "$B" lseend "$A/$m.wav" 900 $v 1 /tmp/ls-$v-$m.json 2>&1 | grep -E "^lseend|rror"; uv run -q analyze_frames.py "$A/$m.rttm" 900 lseend /tmp/ls-$v-$m.json; done
    echo "== $v conversation"; "$B" lseend "$D/fixtures/conversation.wav" 100 $v 1 /tmp/ls-$v-c.json 2>&1 | grep -E "^lseend|rror"; uv run -q analyze_frames.py "$A/conversation.rttm" 100 lseend /tmp/ls-$v-c.json
done
echo "== dihard3 past the documented 1 h: ES2004a 15 min x 6 = 90 min, last repeat scored"
"$B" lseend "$A/ES2004a.wav" 900 dihard3 6 /tmp/ls-long.json 2>&1 | grep -E "^lseend|rror"; uv run -q analyze_frames.py "$A/ES2004a.rttm" 900 lseend /tmp/ls-long.json 4500
