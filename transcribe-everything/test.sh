#!/bin/bash
# ./test.sh [filter] [skip]. One command and one results folder.
# These classes run one at a time: they measure wall clock, or own the Mac's output, keyboard focus, QuickTime and the installed app. The rest run together.
set -uo pipefail
cd "$(dirname "$0")"
caffeinate -i -w $$ &  # an idle sleep mid-run would fail the timed tests for nothing
out="$PWD/test-results/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$out"
alone='AppTests|AttachTests|BarTests|CaptureTests|InstallTests|LiveTests|MicTests|OverlayTests|SelectionTests'
# --filter arguments are alternatives, so the timed pass needs one pattern for "alone and matching".
filter=(${1:+--filter "$1"}); aloneFilter="(?=.*($alone))(?=.*(${1:-}))"; skip=(${2:+--skip "$2"})
swift build -c release --build-tests 2>&1 | tee "$out/log.txt"; status=${PIPESTATUS[0]}
if [ "$status" -eq 0 ]; then
  export TE_RESULTS="$out"  # after the build: a changed environment rebuilds everything
  # Alone first: the parallel group leaves load high for minutes, and timed tests refuse a loaded machine.
  swift test -c release --skip-build --parallel --num-workers 1 --xunit-output "$out/xunit-alone.xml" --filter "$aloneFilter" "${skip[@]+"${skip[@]}"}" 2>&1 | tee -a "$out/log.txt"; b=${PIPESTATUS[0]}
  swift test -c release --skip-build --parallel --num-workers "${TE_WORKERS:-4}" --xunit-output "$out/xunit-parallel.xml" "${filter[@]+"${filter[@]}"}" --skip "$alone" "${skip[@]+"${skip[@]}"}" 2>&1 | tee -a "$out/log.txt"; a=${PIPESTATUS[0]}
  status=$(( a != 0 ? a : b ))
fi
echo "results: $out"
exit "$status"
