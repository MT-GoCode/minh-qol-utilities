#!/bin/bash
# LS-EEND variants and sliding-window tracking on VoxConverse clips (real shows and debates; not LS-EEND's AMI corpus).
S="$(cd "$(dirname "$0")" && pwd)"; V="$HOME/general-purpose/conversation-contexts/transcribe-everything/data/vox"; B="$S/.build/release/Bench"; cd "$S"
for w in "$V"/*.wav; do k=$(basename "$w" .wav); n=$(awk '{print $8}' "$V/$k.rttm" | sort -u | wc -l | tr -d ' '); dur=$(awk '{e=$4+$5; if(e>m)m=e} END{print int(m)+1}' "$V/$k.rttm")
    echo "=== $k: $n speakers, $dur s"
    for v in ami dihard3 callhome; do "$B" lseend "$w" "$dur" $v 1 /tmp/vx.json 2>&1 | grep -E "rror"; printf "%s" "$v"; uv run -q analyze_frames.py "$V/$k.rttm" "$dur" lseend /tmp/vx.json | tail -1; done
    "$B" windows "$w" "$dur" 2.0 0.5 /tmp/vw.json 2>&1 | grep -E "rror"; printf "windows2s "; uv run -q analyze_frames.py "$V/$k.rttm" "$dur" windows /tmp/vw.json | grep -E "thr 0.30"
done
