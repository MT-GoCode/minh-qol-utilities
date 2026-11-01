#!/bin/bash
# usage: run_wid.sh <media file>; prints probe output + mean luma of a window screenshot
cd "$(dirname "$0")"
rm -f wid.out wid.png
./bin/${PROBE:-wid_probe} "$PWD/media/$1" > wid.out 2>&1 &
PID=$!
sleep 3.2
WID=$(grep -o 'windowID=[0-9]*' wid.out | cut -d= -f2)
echo "windowID=$WID"
rac exec screencapture -x -o -l "$WID" "$PWD/wid.png"
wait $PID
cat wid.out
ls -la wid.png
ffmpeg -v error -i wid.png -vf signalstats,metadata=print:file=- -f null - | grep -E 'YAVG|SATAVG' | head -2
