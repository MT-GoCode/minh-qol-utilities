#!/bin/bash
# Every remaining intrusive probe, in order, once HID idle >= 60 s. Each can flip a Bluetooth headset into
# hands-free mode, move the mouse, or play audio, so none may run while Minh is active.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; O="$HOME/.transcribe-everything/probe"
D="$HOME/general-purpose/conversation-contexts/transcribe-everything"
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
wait_idle() { until [ "$(idle)" -ge 60 ]; do sleep 15; done; }
level() { uv run -q -p 3.12 --with soundfile --with numpy python -c "
import soundfile as sf, numpy as np, sys
a,_=sf.read(sys.argv[1]); a=a[16000:9*16000]; print(sys.argv[2], 'rms %.4f peak %.4f'%(np.sqrt((a**2).mean()), abs(a).max()))" "$1" "$2"; }
echo "waiting for HID idle >= 60 s"; wait_idle; echo "== ducking, device selected after voice processing"
"$S/play_and_capture.sh" "$D/fixtures/conversation.wav" 10 sck 16000 >/dev/null 2>&1; level "$O/sck.wav" none
for m in mic mic-vp mic-vpa; do
    wait_idle; rm -f "$O/$m.json"
    ( sleep 1; open -n "$HOME/Applications/TranscribeEverything.app" --args $m 12 ) &
    "$S/play_and_capture.sh" "$D/fixtures/conversation.wav" 10 sck 16000 >/dev/null 2>&1; wait; sleep 4
    grep -E '"device"|"default_input"|"peak"' "$O/$m.json"; level "$O/sck.wav" "$m"
done
wait_idle; echo "== ui"; bash "$S/ui_probe.sh"
OUTPUT="$(system_profiler SPAudioDataType | awk '/^        [^ ].*:$/ {n=$0} /Default Output Device: Yes/ {print n}')"
echo "== default output:$OUTPUT"
case "$OUTPUT" in
    *"MacBook Pro Speakers"*) wait_idle; echo "== echo"; bash "$S/echo_probe.sh" ;;
    *) echo "echo probe not run: needs the Mac speakers as output" ;;
esac
