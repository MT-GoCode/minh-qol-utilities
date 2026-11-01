#!/bin/bash
# usage: run_keys.sh <coupled|decoupled> <inject args...>
cd "$(dirname "$0")"
pgrep -x "Google Chrome" Music Spotify >/dev/null && { echo "refusing to inject media keys: a media app is running"; exit 1; }
m=$1; shift
./bin/keys_probe $m ${AUDIO:-} > keys_$m.out 2>&1 &
PID=$!
sleep 1.5
rac exec "$PWD/bin/inject" "$@"
wait $PID
echo "== $m $*"; cat keys_$m.out
