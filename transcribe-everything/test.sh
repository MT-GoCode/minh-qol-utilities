#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
out="$PWD/test-results/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$out"
TE_RESULTS="$out" swift test -c release --parallel --num-workers 1 --xunit-output "$out/xunit.xml" ${1:+--filter "$1"} ${2:+--skip "$2"} 2>&1 | tee "$out/log.txt"
status=${PIPESTATUS[0]}
echo "results: $out"
exit "$status"
