#!/bin/bash
# usage: run_tap.sh <plain|rac>: tap probe launched plainly or via rac exec, then media keys injected
cd "$(dirname "$0")"
pgrep -x "Google Chrome" Music Spotify >/dev/null && { echo "refusing to inject media keys: a media app is running"; exit 1; }
rm -f tap_$1.out
if [ "$1" = rac ]; then rac exec bash -c "$PWD/bin/tap_probe > $PWD/tap_rac.out 2>&1" & else ./bin/tap_probe > tap_plain.out 2>&1 & fi
PID=$!
for i in $(seq 40); do grep -q "tap enabled" tap_$1.out 2>/dev/null && break; sleep 0.25; done
rac exec "$PWD/bin/inject" x 16 19
wait $PID
echo "== $1"; cat tap_$1.out
